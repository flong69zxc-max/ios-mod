// main.mm - Black Russia Hitbox Patcher (ARM64)
// Fixed compilation errors

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

// ============================================================
// 1. Original hitbox values (little-endian hex)
// ============================================================
typedef struct {
    const char *name;
    uint32_t original;
    uint32_t patched;
} HitboxValue;

static HitboxValue gHitboxes[] = {
    {"HEAD",        0x3E19999A, 0x3E666666},
    {"TORSO_1",     0x3E4CCCCD, 0x3E99999A},
    {"TORSO_2",     0x3E800000, 0x3EC00000},
    {"MID",         0x3E800000, 0x3EC00000},
    {"LEFTARM",     0x3E24E148, 0x3E74E148},
    {"RIGHTARM",    0x3E24E148, 0x3E74E148},
    {"LEFTLEG_1",   0x3E4CCCCD, 0x3E99999A},
    {"RIGHTLEG_1",  0x3E4CCCCD, 0x3E99999A},
    {"LEFTLEG_2",   0x3E19999A, 0x3E666666},
    {"RIGHTLEG_2",  0x3E19999A, 0x3E666666}
};
#define HITBOX_COUNT (sizeof(gHitboxes)/sizeof(gHitboxes[0]))
#define STEP_SIZE 0x20

// ============================================================
// 2. Logging helper
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
// 3. Forward declaration
// ============================================================
static void show_notification(NSString *title, NSString *subtitle);

// ============================================================
// 4. Memory helpers
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
// 5. Find blackrussia-client framework
// ============================================================
typedef struct {
    vm_address_t addr;
    vm_size_t size;
    const char *path;
} MemoryRegion;

static MemoryRegion find_blackrussia_client(void) {
    MemoryRegion result = {0, 0, NULL};
    
    write_log(@"");
    write_log(@"=== LOOKING FOR blackrussia-client.framework ===");
    
    uint32_t imageCount = _dyld_image_count();
    write_log(@"Total loaded images: %d", imageCount);
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        
        NSString *imageName = [NSString stringWithUTF8String:name];
        
        // Look specifically for blackrussia-client
        if ([imageName containsString:@"blackrussia-client"] || 
            [imageName containsString:@"blackrussia-client.framework"]) {
            
            write_log(@"");
            write_log(@"🎯 FOUND blackrussia-client!");
            write_log(@"  Path: %s", name);
            write_log(@"  Header: 0x%llX", (unsigned long long)header);
            write_log(@"  Slide: 0x%lX", (unsigned long)slide);
            write_log(@"  Image index: %d", i);
            
            // Get __DATA segment - fix type
            uint64_t dataSize = 0;
            char *dataPtr = getsectdatafromheader_64(header, "__DATA", "__data", &dataSize);
            
            if (dataPtr) {
                vm_address_t dataAddr = (vm_address_t)dataPtr + slide;
                result.addr = dataAddr;
                result.size = (vm_size_t)dataSize;
                result.path = name;
                
                write_log(@"");
                write_log(@"  __DATA.__data section:");
                write_log(@"    Address: 0x%llX", (unsigned long long)dataAddr);
                write_log(@"    Size: 0x%llX (%llu bytes)", (unsigned long long)dataSize, (unsigned long long)dataSize);
                
                // Also try __DATA_CONST
                uint64_t constSize = 0;
                char *constPtr = getsectdatafromheader_64(header, "__DATA_CONST", "__const", &constSize);
                if (constPtr) {
                    vm_address_t constAddr = (vm_address_t)constPtr + slide;
                    write_log(@"");
                    write_log(@"  __DATA_CONST.__const section:");
                    write_log(@"    Address: 0x%llX", (unsigned long long)constAddr);
                    write_log(@"    Size: 0x%llX", (unsigned long long)constSize);
                }
                
                return result;
            } else {
                write_log(@"  ⚠️ Could not find __DATA.__data section");
                write_log(@"  Trying to scan the whole image...");
                
                // If we can't find data section, scan the whole image
                result.addr = (vm_address_t)header + slide;
                result.size = 0x1000000; // 16MB - approximate size
                result.path = name;
                return result;
            }
        }
    }
    
    // If not found, try to find any Black Russia related image
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        NSString *imageName = [NSString stringWithUTF8String:name];
        
        if ([imageName containsString:@"black"] || 
            [imageName containsString:@"Black"] ||
            [imageName containsString:@"russia"] ||
            [imageName containsString:@"Russia"]) {
            
            write_log(@"");
            write_log(@"🔍 Found potential Black Russia image: %s", name);
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            
            result.addr = (vm_address_t)header + slide;
            result.size = 0x1000000;
            result.path = name;
            return result;
        }
    }
    
    write_log(@"❌ blackrussia-client not found!");
    return result;
}

// ============================================================
// 6. Scan for pattern
// ============================================================
static vm_address_t scan_for_pattern(vm_address_t start, vm_size_t size) {
    if (start == 0 || size == 0) {
        return 0;
    }
    
    write_log(@"");
    write_log(@"=== SCANNING FOR HITBOX PATTERN ===");
    write_log(@"Address: 0x%llX - 0x%llX (size: 0x%llX)", 
             (unsigned long long)start, 
             (unsigned long long)(start + size), 
             (unsigned long long)size);
    write_log(@"Looking for HEAD (0x3E19999A) followed by TORSO_1 (0x3E4CCCCD) at +0x20");
    write_log(@"");
    
    uint32_t buf = 0;
    int checked = 0;
    int foundCandidates = 0;
    
    for (vm_address_t addr = start; addr < start + size - 4; addr += 4) {
        checked++;
        if (checked % 500000 == 0) {
            write_log(@"  Scanned %d positions, current: 0x%llX", checked, (unsigned long long)addr);
        }
        
        if (!read_memory(addr, &buf, 4)) continue;
        
        // Check for HEAD
        if (buf == gHitboxes[0].original) {
            foundCandidates++;
            
            // Check for TORSO_1 at +0x20
            vm_address_t torsoAddr = addr + STEP_SIZE;
            uint32_t torsoBuf = 0;
            
            if (read_memory(torsoAddr, &torsoBuf, 4) && torsoBuf == gHitboxes[1].original) {
                write_log(@"");
                write_log(@"🔍 Found candidate #%d at 0x%llX", foundCandidates, (unsigned long long)addr);
                write_log(@"   HEAD: 0x%08X", buf);
                write_log(@"   TORSO_1: 0x%08X at 0x%llX", torsoBuf, (unsigned long long)torsoAddr);
                
                // Verify all 10 values
                BOOL allMatch = YES;
                for (int i = 0; i < HITBOX_COUNT; i++) {
                    vm_address_t checkAddr = addr + i * STEP_SIZE;
                    uint32_t checkBuf = 0;
                    
                    if (!read_memory(checkAddr, &checkBuf, 4)) {
                        write_log(@"  ✗ Cannot read %s at 0x%llX", gHitboxes[i].name, (unsigned long long)checkAddr);
                        allMatch = NO;
                        break;
                    }
                    
                    if (checkBuf != gHitboxes[i].original) {
                        write_log(@"  ✗ %s: expected 0x%08X, got 0x%08X at 0x%llX", 
                                 gHitboxes[i].name, gHitboxes[i].original, checkBuf, 
                                 (unsigned long long)checkAddr);
                        allMatch = NO;
                        break;
                    }
                    
                    write_log(@"  ✓ %s: 0x%08X at 0x%llX", 
                             gHitboxes[i].name, checkBuf, (unsigned long long)checkAddr);
                }
                
                if (allMatch) {
                    write_log(@"");
                    write_log(@"✅ ALL 10 HITBOXES VERIFIED!");
                    return addr;
                }
            }
        }
    }
    
    write_log(@"");
    write_log(@"Scanned %d positions, found %d HEAD candidates", checked, foundCandidates);
    write_log(@"❌ Full pattern not found");
    return 0;
}

// ============================================================
// 7. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    write_log(@"");
    write_log(@"╔══════════════════════════════════════════════╗");
    write_log(@"║    BLACK RUSSIA HITBOX PATCHER v3.1        ║");
    write_log(@"║      Targeting blackrussia-client           ║");
    write_log(@"╚══════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    write_log(@"Task port: %d", gTask);
    
    // Find blackrussia-client
    MemoryRegion brClient = find_blackrussia_client();
    
    if (brClient.addr == 0 || brClient.size == 0) {
        write_log(@"");
        write_log(@"❌ COULD NOT FIND blackrussia-client!");
        show_notification(@"blackrussia-client not found.", @"Check HitBoxes.log");
        return;
    }
    
    // Scan for pattern
    vm_address_t found = scan_for_pattern(brClient.addr, brClient.size);
    
    if (!found) {
        write_log(@"");
        write_log(@"❌ HITBOXES NOT FOUND!");
        show_notification(@"Hitboxes not found.", @"Check HitBoxes.log");
        return;
    }
    
    write_log(@"");
    write_log(@"╔══════════════════════════════════════════════╗");
    write_log(@"║        PATCHING HITBOXES                    ║");
    write_log(@"╚══════════════════════════════════════════════╝");
    write_log(@"");
    
    // Patch all values
    BOOL success = YES;
    for (int i = 0; i < HITBOX_COUNT; i++) {
        vm_address_t patchAddr = found + i * STEP_SIZE;
        uint32_t originalValue = 0;
        uint32_t newValue = gHitboxes[i].patched;
        
        read_memory(patchAddr, &originalValue, 4);
        
        float originalFloat = *(float*)&originalValue;
        float newFloat = *(float*)&newValue;
        
        write_log(@"Patching %s at 0x%llX:", gHitboxes[i].name, (unsigned long long)patchAddr);
        write_log(@"  Original: 0x%08X (%.4f)", originalValue, originalFloat);
        write_log(@"  New:      0x%08X (%.4f)", newValue, newFloat);
        
        if (!write_memory(patchAddr, &newValue, 4)) {
            success = NO;
            write_log(@"  ✗ WRITE FAILED!");
            break;
        }
        
        // Verify
        uint32_t verifyValue = 0;
        read_memory(patchAddr, &verifyValue, 4);
        if (verifyValue == newValue) {
            write_log(@"  ✓ SUCCESS");
        } else {
            write_log(@"  ✗ VERIFY FAILED! Expected 0x%08X got 0x%08X", newValue, verifyValue);
            success = NO;
            break;
        }
    }
    
    write_log(@"");
    if (success) {
        write_log(@"╔══════════════════════════════════════════════╗");
        write_log(@"║        ✓ ALL HITBOXES PATCHED!             ║");
        write_log(@"╚══════════════════════════════════════════════╝");
        NSString *msg = [NSString stringWithFormat:@"Offset: 0x%llX", (unsigned long long)found];
        show_notification(@"Hitboxes patched successfully!", msg);
    } else {
        write_log(@"╔══════════════════════════════════════════════╗");
        write_log(@"║        ❌ PATCH FAILED!                    ║");
        write_log(@"╚══════════════════════════════════════════════╝");
        show_notification(@"Patch failed.", @"Check HitBoxes.log");
    }
}

// ============================================================
// 8. Notification display
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
                // Try to get any window from scenes
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
// 9. Entry point
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    write_log(@"╔══════════════════════════════════════════════╗");
    write_log(@"║   BLACK RUSSIA HITBOX PATCHER INJECTED     ║");
    write_log(@"║   Target: blackrussia-client.framework     ║");
    write_log(@"╚══════════════════════════════════════════════╝");
    write_log(@"Waiting 5 seconds for Black Russia to fully load...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

// ============================================================
// 10. Dummy export
// ============================================================
extern "C" void __dummy_export(void) {}

// ============================================================
// Compile:
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//   -framework Foundation -framework UIKit \
//   -o mylib.dylib main.mm
// ============================================================
