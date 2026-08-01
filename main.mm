// main.mm - Black Russia Hitbox Patcher (ARM64)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mutex>
#import <vector>

typedef struct {
    const char *name;
    uint32_t original;
    float originalFloat;
    uint32_t patched;
    float patchedFloat;
} HitboxValue;

static const HitboxValue gHitboxes[] = {
    {"HEAD",        0x3E19999A, 0.15f, 0x3E99999A, 0.30f},
    {"TORSO_1",     0x3E4CCCCD, 0.20f, 0x3ECCCCCD, 0.40f},
    {"TORSO_2",     0x3E800000, 0.25f, 0x3F000000, 0.50f},
    {"MID",         0x3E800000, 0.25f, 0x3F000000, 0.50f},
    {"LEFTARM",     0x3E23D70A, 0.16f, 0x3EA3D70A, 0.32f},
    {"RIGHTARM",    0x3E23D70A, 0.16f, 0x3EA3D70A, 0.32f},
    {"LEFTLEG_1",   0x3E4CCCCD, 0.20f, 0x3ECCCCCD, 0.40f},
    {"RIGHTLEG_1",  0x3E4CCCCD, 0.20f, 0x3ECCCCCD, 0.40f},
    {"LEFTLEG_2",   0x3E19999A, 0.15f, 0x3E99999A, 0.30f},
    {"RIGHTLEG_2",  0x3E19999A, 0.15f, 0x3E99999A, 0.30f}
};

#define HITBOX_COUNT (sizeof(gHitboxes)/sizeof(gHitboxes[0]))
#define STEP_SIZE 0x20
#define TOLERANCE 0.005f

static vm_address_t gFrameworkBase = 0;
static bool gPatched = false;
static std::mutex gPatchMutex;
static mach_port_t gTask = MACH_PORT_NULL;
static vm_address_t gHitboxesAbsoluteAddr = 0;
static vm_address_t gHitboxesRelativeAddr = 0;

typedef struct {
    vm_address_t absolute;
    vm_size_t size;
    const char *name;
} MemorySection;

static std::vector<MemorySection> gSections;

static void write_log(NSString *format, ...) {
    static std::mutex logMutex;
    std::lock_guard<std::mutex> lock(logMutex);
    
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths firstObject];
        NSString *savesPath = [documentsPath stringByAppendingPathComponent:@"saves"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:savesPath]) {
            [fileManager createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"HitBoxes.log"];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        
        NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } else {
            [logEntry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        NSLog(@"%@", logEntry);
    }
}

static void show_notification(NSString *title, NSString *subtitle) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                    if (window) break;
                }
            }
        }
        
        if (!window) {
            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        NSArray *windows = scene.windows;
                        if (windows.count > 0) {
                            window = windows.firstObject;
                            break;
                        }
                    }
                }
            } else {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                NSArray *windows = [UIApplication sharedApplication].windows;
                if (windows.count > 0) {
                    window = windows.firstObject;
                }
                #pragma clang diagnostic pop
            }
        }
        
        UIViewController *rootVC = window.rootViewController;
        
        if (rootVC) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:title
                message:subtitle
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        } else {
            NSLog(@"%@: %@", title, subtitle);
        }
    });
}

static bool read_memory_safe(vm_address_t absoluteAddr, void *buffer, size_t size) {
    if (absoluteAddr == 0 || buffer == NULL || size == 0) return false;
    
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(gTask, absoluteAddr, size,
                                         (vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

static bool write_memory_safe(vm_address_t absoluteAddr, const void *buffer, size_t size) {
    if (absoluteAddr == 0 || buffer == NULL || size == 0) return false;
    
    vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;
    vm_protect(gTask, absoluteAddr, size, false, prot);
    
    kern_return_t kr = vm_write(gTask, absoluteAddr, (vm_offset_t)buffer, size);
    return (kr == KERN_SUCCESS);
}

static vm_address_t find_blackrussia_framework(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     SEARCHING blackrussia-client.framework               ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    
    uint32_t imageCount = _dyld_image_count();
    write_log(@"Total images: %d", imageCount);
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        
        NSString *imageName = [NSString stringWithUTF8String:name];
        if ([imageName containsString:@"blackrussia-client"]) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!header) continue;
            
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            gFrameworkBase = (vm_address_t)header + slide;
            
            write_log(@"");
            write_log(@"FOUND!");
            write_log(@"  Base address: 0x%llX", (unsigned long long)gFrameworkBase);
            
            gSections.clear();
            uint64_t size = 0;
            
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            char *data = getsectdatafromheader_64(header, "__DATA", "__data", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA.__data"};
                gSections.push_back(sect);
            }
            
            data = getsectdatafromheader_64(header, "__DATA", "__const", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA.__const"};
                gSections.push_back(sect);
            }
            
            data = getsectdatafromheader_64(header, "__DATA_CONST", "__const", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA_CONST.__const"};
                gSections.push_back(sect);
            }
            
            data = getsectdatafromheader_64(header, "__DATA", "__bss", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA.__bss"};
                gSections.push_back(sect);
            }
#pragma clang diagnostic pop
            
            write_log(@"");
            write_log(@"Sections found: %zu", gSections.size());
            
            return gFrameworkBase;
        }
    }
    
    write_log(@"blackrussia-client NOT FOUND!");
    return 0;
}

static vm_address_t find_hitboxes_absolute(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     SEARCHING HITBOXES IN ABSOLUTE ADDRESSES            ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    write_log(@"Pattern: %d values, step 0x%X", HITBOX_COUNT, STEP_SIZE);
    for (int i = 0; i < HITBOX_COUNT; i++) {
        write_log(@"  +0x%03X: %s = %.3f (0x%08X)", 
                 i * STEP_SIZE, 
                 gHitboxes[i].name, 
                 gHitboxes[i].originalFloat,
                 gHitboxes[i].original);
    }
    write_log(@"");
    
    size_t totalScanned = 0;
    
    for (const auto& sect : gSections) {
        vm_address_t startAbsolute = sect.absolute;
        vm_size_t size = sect.size;
        
        if (size < HITBOX_COUNT * STEP_SIZE) continue;
        
        write_log(@"");
        write_log(@"Scanning %s (0x%llX bytes)", sect.name, (unsigned long long)size);
        write_log(@"  Start absolute: 0x%llX", (unsigned long long)startAbsolute);
        
        size_t scanned = 0;
        size_t candidates = 0;
        
        for (vm_address_t addr = startAbsolute; 
             addr <= startAbsolute + size - (HITBOX_COUNT * STEP_SIZE); 
             addr += 4) {
            
            scanned++;
            totalScanned++;
            
            if (scanned % 100000 == 0) {
                write_log(@"  Scanned %zu positions in %s", scanned, sect.name);
            }
            
            uint32_t headVal = 0;
            if (!read_memory_safe(addr, &headVal, 4)) continue;
            if (headVal != gHitboxes[0].original) continue;
            
            bool allMatch = true;
            int matched = 0;
            
            for (int i = 0; i < HITBOX_COUNT; i++) {
                vm_address_t checkAddr = addr + i * STEP_SIZE;
                uint32_t val = 0;
                if (!read_memory_safe(checkAddr, &val, 4)) {
                    allMatch = false;
                    break;
                }
                
                float actual = *(float*)&val;
                float expected = gHitboxes[i].originalFloat;
                
                if (fabs(actual - expected) <= TOLERANCE) {
                    matched++;
                } else {
                    allMatch = false;
                    break;
                }
            }
            
            if (allMatch && matched == HITBOX_COUNT) {
                candidates++;
                
                gHitboxesAbsoluteAddr = addr;
                gHitboxesRelativeAddr = addr - gFrameworkBase;
                
                uint64_t relativeDisplay = (uint64_t)(gHitboxesRelativeAddr & 0xFFFFFFFFFFFFFFFF);
                uint64_t absoluteDisplay = (uint64_t)addr;
                uint64_t baseDisplay = (uint64_t)gFrameworkBase;
                
                write_log(@"");
                write_log(@"FOUND candidate #%zu!", candidates);
                write_log(@"  ABSOLUTE address: 0x%llX", absoluteDisplay);
                write_log(@"  Base address:     0x%llX", baseDisplay);
                write_log(@"  RELATIVE (RVA):   0x%llX", relativeDisplay);
                write_log(@"  Section: %s", sect.name);
                write_log(@"");
                write_log(@"Verified values:");
                
                for (int i = 0; i < HITBOX_COUNT; i++) {
                    vm_address_t checkAddr = addr + i * STEP_SIZE;
                    uint32_t val = 0;
                    read_memory_safe(checkAddr, &val, 4);
                    float actual = *(float*)&val;
                    write_log(@"  +0x%03X %s: 0x%08X = %.3f", 
                             i * STEP_SIZE, gHitboxes[i].name, val, actual);
                }
                
                write_log(@"");
                write_log(@"╔═══════════════════════════════════════════════════════════╗");
                write_log(@"║     ALL %d HITBOXES FOUND!                              ║", HITBOX_COUNT);
                write_log(@"║     ABSOLUTE: 0x%llX                                    ║", absoluteDisplay);
                write_log(@"║     RELATIVE: 0x%llX                                    ║", relativeDisplay);
                write_log(@"║     Formula: 0x%llX - 0x%llX = 0x%llX                   ║", 
                         absoluteDisplay, baseDisplay, relativeDisplay);
                write_log(@"╚═══════════════════════════════════════════════════════════╝");
                
                return addr;
            }
        }
        
        write_log(@"  Scanned %zu positions, candidates: %zu", scanned, candidates);
    }
    
    write_log(@"");
    write_log(@"Hitboxes NOT found!");
    write_log(@"Total scanned: %zu positions", totalScanned);
    return 0;
}

static bool patch_hitboxes_absolute(vm_address_t absoluteAddr) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     APPLYING PATCHES (x2)                                ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    if (absoluteAddr == 0) {
        write_log(@"Invalid absolute address!");
        return false;
    }
    
    uint64_t absoluteDisplay = (uint64_t)absoluteAddr;
    uint64_t baseDisplay = (uint64_t)gFrameworkBase;
    uint64_t relativeDisplay = (uint64_t)(gHitboxesRelativeAddr & 0xFFFFFFFFFFFFFFFF);
    
    write_log(@"  Absolute start: 0x%llX", absoluteDisplay);
    write_log(@"  Base address:   0x%llX", baseDisplay);
    write_log(@"  Relative (RVA): 0x%llX", relativeDisplay);
    write_log(@"");
    
    bool allSuccess = true;
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        vm_address_t patchAddr = absoluteAddr + i * STEP_SIZE;
        uint32_t newValue = gHitboxes[i].patched;
        float newFloat = *(float*)&newValue;
        
        uint32_t originalValue = 0;
        read_memory_safe(patchAddr, &originalValue, 4);
        float originalFloat = *(float*)&originalValue;
        
        write_log(@"%s:", gHitboxes[i].name);
        write_log(@"  Address:  0x%llX", (unsigned long long)patchAddr);
        write_log(@"  Original: 0x%08X (%.3f)", originalValue, originalFloat);
        write_log(@"  New:      0x%08X (%.3f) x2", newValue, newFloat);
        
        if (!write_memory_safe(patchAddr, &newValue, 4)) {
            allSuccess = false;
            write_log(@"  WRITE FAILED!");
            break;
        }
        
        uint32_t verifyValue = 0;
        read_memory_safe(patchAddr, &verifyValue, 4);
        
        if (verifyValue == newValue) {
            write_log(@"  VERIFIED");
        } else {
            allSuccess = false;
            write_log(@"  VERIFY FAILED!");
            break;
        }
        write_log(@"");
    }
    
    return allSuccess;
}

static void patch_hitboxes(void) {
    std::lock_guard<std::mutex> lock(gPatchMutex);
    
    if (gPatched) {
        write_log(@"Patch already applied!");
        return;
    }
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     BLACK RUSSIA HITBOX PATCHER v13.0                   ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    write_log(@"Task port: %d", gTask);
    
    if (!find_blackrussia_framework() || gFrameworkBase == 0) {
        write_log(@"Failed to find blackrussia-client.framework");
        show_notification(@"Error", @"Framework not found");
        return;
    }
    
    vm_address_t foundAbsolute = find_hitboxes_absolute();
    if (!foundAbsolute) {
        write_log(@"Hitboxes not found!");
        show_notification(@"Error", @"Hitboxes not found");
        return;
    }
    
    bool success = patch_hitboxes_absolute(foundAbsolute);
    
    if (success) {
        gPatched = true;
        
        uint64_t absoluteDisplay = (uint64_t)gHitboxesAbsoluteAddr;
        uint64_t baseDisplay = (uint64_t)gFrameworkBase;
        uint64_t relativeDisplay = (uint64_t)(gHitboxesRelativeAddr & 0xFFFFFFFFFFFFFFFF);
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║     ALL 10 HITBOXES PATCHED!                            ║");
        write_log(@"║                                                          ║");
        write_log(@"║     ABSOLUTE: 0x%llX                                    ║", absoluteDisplay);
        write_log(@"║     Base:     0x%llX                                    ║", baseDisplay);
        write_log(@"║     RELATIVE: 0x%llX                                    ║", relativeDisplay);
        write_log(@"║                                                          ║");
        write_log(@"║     Formula: 0x%llX - 0x%llX = 0x%llX                   ║", 
                 absoluteDisplay, baseDisplay, relativeDisplay);
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        
        NSString *msg = [NSString stringWithFormat:
            @"Absolute: 0x%llX\n"
            @"Relative: 0x%llX\n"
            @"x2 Hitboxes active!",
            absoluteDisplay, relativeDisplay];
        show_notification(@"Patch applied successfully!", msg);
        
    } else {
        write_log(@"");
        write_log(@"PATCH FAILED!");
        show_notification(@"Error", @"Patch failed. Check logs.");
    }
}

__attribute__((constructor))
static void initialize(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     HITBOX PATCHER INJECTED v13.0                       ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    write_log(@"Waiting 5 seconds for game to load...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

extern "C" void __dummy_export(void) {}
