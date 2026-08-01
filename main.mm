// main.mm - Black Russia Hitbox Patcher (ARM64)
// Scans ALL sections of blackrussia-client.framework

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

// ============================================================
// 1. Original hitbox values (from memory dump)
// ============================================================
typedef struct {
    const char *name;
    uint32_t original;
    uint32_t patched;
    float originalFloat;
    float patchedFloat;
} HitboxValue;

static HitboxValue gHitboxes[] = {
    {"HEAD",        0x3E19999A, 0x3E99999A, 0.15f, 0.30f},
    {"TORSO_1",     0x3E4CCCCD, 0x3ECCCCCD, 0.20f, 0.40f},
    {"TORSO_2",     0x3E800000, 0x3F000000, 0.25f, 0.50f},
    {"MID",         0x3E800000, 0x3F000000, 0.25f, 0.50f},
    {"LEFTARM",     0x3E23D70A, 0x3EA3D70A, 0.16f, 0.32f},
    {"RIGHTARM",    0x3E23D70A, 0x3EA3D70A, 0.16f, 0.32f},
    {"LEFTLEG_1",   0x3E4CCCCD, 0x3ECCCCCD, 0.20f, 0.40f},
    {"RIGHTLEG_1",  0x3E4CCCCD, 0x3ECCCCCD, 0.20f, 0.40f},
    {"LEFTLEG_2",   0x3E19999A, 0x3E99999A, 0.15f, 0.30f},
    {"RIGHTLEG_2",  0x3E19999A, 0x3E99999A, 0x15f, 0.30f}
};
#define HITBOX_COUNT (sizeof(gHitboxes)/sizeof(gHitboxes[0]))
#define STEP_SIZE 0x20
#define TOLERANCE 0.001f

// ============================================================
// 2. Memory helpers
// ============================================================
static mach_port_t gTask = MACH_PORT_NULL;

static BOOL read_memory(vm_address_t addr, void *buffer, size_t size) {
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(gTask, addr, size,
                                         (vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

static BOOL write_memory(vm_address_t addr, const void *buffer, size_t size) {
    kern_return_t kr = vm_write(gTask, addr, (vm_offset_t)buffer, size);
    return (kr == KERN_SUCCESS);
}

// ============================================================
// 3. Logging helper
// ============================================================
static void write_log(NSString *format, ...) {
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

// ============================================================
// 4. Hex dump helper
// ============================================================
static NSString *hexDump(vm_address_t addr, size_t length) {
    NSMutableString *hex = [NSMutableString string];
    uint8_t buffer[256];
    size_t toRead = length > 256 ? 256 : length;
    
    if (!read_memory(addr, buffer, toRead)) {
        return @"[CAN'T READ]";
    }
    
    for (size_t i = 0; i < toRead; i++) {
        [hex appendFormat:@"%02X ", buffer[i]];
        if ((i + 1) % 16 == 0) [hex appendString:@"\n              "];
    }
    return hex;
}

// ============================================================
// 5. Forward declaration
// ============================================================
static void show_notification(NSString *title, NSString *subtitle);

// ============================================================
// 6. Find blackrussia-client framework and ALL sections
// ============================================================
typedef struct {
    vm_address_t addr;
    vm_size_t size;
    const char *name;
} MemorySection;

static MemorySection gSections[10];
static int gSectionCount = 0;

static void add_section(vm_address_t addr, vm_size_t size, const char *name) {
    if (addr == 0 || size == 0) return;
    if (gSectionCount < 10) {
        gSections[gSectionCount].addr = addr;
        gSections[gSectionCount].size = size;
        gSections[gSectionCount].name = name;
        gSectionCount++;
        write_log(@"  📁 %s: 0x%llX - 0x%llX (size: 0x%llX)", 
                 name, (unsigned long long)addr, 
                 (unsigned long long)(addr + size), 
                 (unsigned long long)size);
    }
}

static vm_address_t find_blackrussia_framework(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║        SCANNING blackrussia-client.framework             ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    uint32_t imageCount = _dyld_image_count();
    write_log(@"📊 Total loaded images: %d", imageCount);
    write_log(@"");
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        NSString *imageName = [NSString stringWithUTF8String:name];
        
        if ([imageName containsString:@"blackrussia-client"]) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            
            write_log(@"🎯 FOUND blackrussia-client!");
            write_log(@"  ┌─────────────────────────────────────────────");
            write_log(@"  │ Image index: %d", i);
            write_log(@"  │ Path: %s", name);
            write_log(@"  │ Header: 0x%llX", (unsigned long long)header);
            write_log(@"  │ Slide: 0x%lX", (unsigned long)slide);
            write_log(@"  └─────────────────────────────────────────────");
            write_log(@"");
            write_log(@"📁 Scanning all sections...");
            
            gSectionCount = 0;
            
            // Get all sections
            uint64_t size = 0;
            
            // __DATA.__data
            char *ptr = getsectdatafromheader_64(header, "__DATA", "__data", &size);
            if (ptr) add_section((vm_address_t)ptr + slide, size, "__DATA.__data");
            
            // __DATA.__const
            ptr = getsectdatafromheader_64(header, "__DATA", "__const", &size);
            if (ptr) add_section((vm_address_t)ptr + slide, size, "__DATA.__const");
            
            // __DATA_CONST.__const
            ptr = getsectdatafromheader_64(header, "__DATA_CONST", "__const", &size);
            if (ptr) add_section((vm_address_t)ptr + slide, size, "__DATA_CONST.__const");
            
            // __DATA.__bss
            ptr = getsectdatafromheader_64(header, "__DATA", "__bss", &size);
            if (ptr) add_section((vm_address_t)ptr + slide, size, "__DATA.__bss");
            
            // __TEXT.__text
            ptr = getsectdatafromheader_64(header, "__TEXT", "__text", &size);
            if (ptr) add_section((vm_address_t)ptr + slide, size, "__TEXT.__text");
            
            // __TEXT.__const
            ptr = getsectdatafromheader_64(header, "__TEXT", "__const", &size);
            if (ptr) add_section((vm_address_t)ptr + slide, size, "__TEXT.__const");
            
            write_log(@"");
            write_log(@"📊 Total sections found: %d", gSectionCount);
            
            return (vm_address_t)header + slide;
        }
    }
    
    write_log(@"❌ blackrussia-client NOT FOUND!");
    return 0;
}

// ============================================================
// 7. Search with tolerance in ALL sections
// ============================================================
static vm_address_t find_in_all_sections(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║      SCANNING ALL SECTIONS WITH TOLERANCE (%.3f)        ║", TOLERANCE);
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    write_log(@"🔍 Looking for pattern from memory dump:");
    write_log(@"  0x...888: 9A 99 19 3E (HEAD)");
    write_log(@"  0x...8A8: CD CC 4C 3E (TORSO_1)");
    write_log(@"  0x...8C8: 00 00 80 3E (TORSO_2)");
    write_log(@"  0x...8E8: 00 00 80 3E (MID)");
    write_log(@"  0x...908: 0A D7 23 3E (LEFTARM)");
    write_log(@"");
    
    int totalScanned = 0;
    
    for (int si = 0; si < gSectionCount; si++) {
        vm_address_t start = gSections[si].addr;
        vm_size_t size = gSections[si].size;
        const char *sectName = gSections[si].name;
        
        write_log(@"");
        write_log(@"🔎 Scanning %s:", sectName);
        write_log(@"  Range: 0x%llX - 0x%llX (size: 0x%llX)", 
                 (unsigned long long)start, 
                 (unsigned long long)(start + size), 
                 (unsigned long long)size);
        
        int checked = 0;
        int candidates = 0;
        
        for (vm_address_t addr = start; addr < start + size - 4; addr += 4) {
            checked++;
            totalScanned++;
            
            if (checked % 50000 == 0) {
                write_log(@"  Scanned %d positions in %s", checked, sectName);
            }
            
            // Check HEAD (exact match required)
            uint32_t headVal = 0;
            if (!read_memory(addr, &headVal, 4)) continue;
            if (headVal != gHitboxes[0].original) continue;
            
            // Check TORSO_1 at +0x20 (exact match required)
            uint32_t torsoVal = 0;
            if (!read_memory(addr + STEP_SIZE, &torsoVal, 4)) continue;
            if (torsoVal != gHitboxes[1].original) continue;
            
            candidates++;
            write_log(@"");
            write_log(@"  🔍 Candidate #%d at 0x%llX (in %s)", 
                     candidates, (unsigned long long)addr, sectName);
            
            // Check remaining values with tolerance
            BOOL allMatch = YES;
            int matched = 2;
            
            for (int i = 2; i < HITBOX_COUNT; i++) {
                vm_address_t checkAddr = addr + i * STEP_SIZE;
                uint32_t val = 0;
                if (!read_memory(checkAddr, &val, 4)) {
                    allMatch = NO;
                    break;
                }
                
                float actual = *(float*)&val;
                float expected = gHitboxes[i].originalFloat;
                float diff = fabs(actual - expected);
                
                if (diff <= TOLERANCE) {
                    matched++;
                } else {
                    write_log(@"    ✗ %s: expected 0x%08X (%.3f), got 0x%08X (%.3f)", 
                             gHitboxes[i].name, gHitboxes[i].original, expected, val, actual);
                    allMatch = NO;
                }
            }
            
            if (allMatch && matched == HITBOX_COUNT) {
                write_log(@"");
                write_log(@"╔═══════════════════════════════════════════════════════════╗");
                write_log(@"║     ✅ ALL %d HITBOXES MATCHED in %s!                    ║", HITBOX_COUNT, sectName);
                write_log(@"╚═══════════════════════════════════════════════════════════╝");
                write_log(@"");
                write_log(@"📍 Found at: 0x%llX", (unsigned long long)addr);
                
                // Show all values
                for (int i = 0; i < HITBOX_COUNT; i++) {
                    vm_address_t checkAddr = addr + i * STEP_SIZE;
                    uint32_t val = 0;
                    read_memory(checkAddr, &val, 4);
                    write_log(@"  %s: 0x%08X (%.3f) at 0x%llX", 
                             gHitboxes[i].name, val, *(float*)&val, (unsigned long long)checkAddr);
                }
                
                return addr;
            }
        }
        
        write_log(@"  Scanned %d positions in %s, found %d candidates", checked, sectName, candidates);
    }
    
    write_log(@"");
    write_log(@"❌ Pattern not found. Total scanned: %d positions", totalScanned);
    return 0;
}

// ============================================================
// 8. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║        BLACK RUSSIA HITBOX PATCHER v8.0                 ║");
    write_log(@"║        Scanning ALL sections of framework                ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    write_log(@"🔑 Task port: %d", gTask);
    write_log(@"");
    
    // Show target values
    write_log(@"📋 Target values (x2):");
    for (int i = 0; i < HITBOX_COUNT; i++) {
        write_log(@"  %s: %.3f → %.3f", 
                 gHitboxes[i].name, 
                 gHitboxes[i].originalFloat, 
                 gHitboxes[i].patchedFloat);
    }
    write_log(@"");
    
    // Find framework and all sections
    vm_address_t base = find_blackrussia_framework();
    
    if (base == 0 || gSectionCount == 0) {
        write_log(@"");
        write_log(@"❌ CRITICAL: blackrussia-client NOT FOUND!");
        show_notification(@"blackrussia-client not found.", @"Check HitBoxes.log");
        return;
    }
    
    // Search in all sections
    vm_address_t found = find_in_all_sections();
    
    if (!found) {
        write_log(@"");
        write_log(@"❌ HITBOXES NOT FOUND!");
        show_notification(@"Hitboxes not found.", @"Check HitBoxes.log");
        return;
    }
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║              APPLYING PATCHES (x2)                       ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    BOOL success = YES;
    for (int i = 0; i < HITBOX_COUNT; i++) {
        vm_address_t patchAddr = found + i * STEP_SIZE;
        uint32_t originalValue = 0;
        uint32_t newValue = gHitboxes[i].patched;
        
        read_memory(patchAddr, &originalValue, 4);
        
        float originalFloat = *(float*)&originalValue;
        float newFloat = *(float*)&newValue;
        
        write_log(@"📝 %s:", gHitboxes[i].name);
        write_log(@"  Address:  0x%llX", (unsigned long long)patchAddr);
        write_log(@"  Original: 0x%08X (%.3f)", originalValue, originalFloat);
        write_log(@"  New:      0x%08X (%.3f) x2", newValue, newFloat);
        
        if (!write_memory(patchAddr, &newValue, 4)) {
            success = NO;
            write_log(@"  ❌ WRITE FAILED!");
            break;
        }
        
        uint32_t verifyValue = 0;
        read_memory(patchAddr, &verifyValue, 4);
        if (verifyValue == newValue) {
            write_log(@"  ✅ VERIFIED");
        } else {
            write_log(@"  ❌ VERIFY FAILED!");
            success = NO;
            break;
        }
        write_log(@"");
    }
    
    write_log(@"");
    if (success) {
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║     ✅ ALL 10 HITBOXES PATCHED! (x2 damage)             ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        NSString *msg = [NSString stringWithFormat:@"Offset: 0x%llX\nx2 Hitboxes active!", (unsigned long long)found];
        show_notification(@"Hitboxes patched successfully!", msg);
    } else {
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║              ❌ PATCH FAILED!                            ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        show_notification(@"Patch failed.", @"Check HitBoxes.log");
    }
}

// ============================================================
// 9. Notification display
// ============================================================
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
                NSArray *windows = [UIApplication sharedApplication].windows;
                if (windows.count > 0) {
                    window = windows.firstObject;
                }
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

// ============================================================
// 10. Entry point
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║      BLACK RUSSIA HITBOX PATCHER v8.0 INJECTED          ║");
    write_log(@"║      Scanning ALL sections of framework                  ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    write_log(@"⏳ Waiting 5 seconds for Black Russia to fully load...");
    write_log(@"");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

// ============================================================
// 11. Dummy export
// ============================================================
extern "C" void __dummy_export(void) {}

// ============================================================
// Compile:
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//   -framework Foundation -framework UIKit \
//   -o mylib.dylib main.mm
// ============================================================
