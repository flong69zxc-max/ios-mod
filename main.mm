// main.mm - Black Russia Hitbox Patcher (ARM64)
// Correct pattern search with 0x20 spacing

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ============================================================
// 1. Original hitbox values (little-endian hex)
// STRUCTURE: each value is 4 bytes, followed by 28 bytes of zeros/garbage
// Total spacing = 32 bytes (0x20) between values
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
#define STEP_SIZE 0x20 // 32 bytes between each hitbox

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
// 5. Pattern matching function
// ============================================================
static BOOL check_hitbox_pattern_at_address(vm_address_t addr) {
    uint32_t value = 0;
    
    write_log(@"  Verifying pattern at 0x%llX:", (unsigned long long)addr);
    
    // Check all 10 values with 0x20 spacing
    for (int i = 0; i < HITBOX_COUNT; i++) {
        vm_address_t checkAddr = addr + i * STEP_SIZE;
        
        if (!read_memory(checkAddr, &value, 4)) {
            write_log(@"    ✗ FAIL: Cannot read %s at 0x%llX", 
                     gHitboxes[i].name, (unsigned long long)checkAddr);
            return NO;
        }
        
        if (value != gHitboxes[i].original) {
            write_log(@"    ✗ FAIL: %s expected 0x%08X got 0x%08X at 0x%llX", 
                     gHitboxes[i].name, gHitboxes[i].original, value, 
                     (unsigned long long)checkAddr);
            return NO;
        }
        
        write_log(@"    ✓ %s: 0x%08X at 0x%llX", 
                 gHitboxes[i].name, value, (unsigned long long)checkAddr);
    }
    
    write_log(@"  ✓ FULL PATTERN MATCHED at 0x%llX!", (unsigned long long)addr);
    return YES;
}

// ============================================================
// 6. Scan memory for pattern
// ============================================================
static vm_address_t scan_memory_for_pattern(void) {
    vm_address_t address = 0;
    vm_size_t size = 0;
    vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    natural_t depth = 0;
    int regionCount = 0;
    int scannedRegions = 0;
    uint32_t firstValue = gHitboxes[0].original;
    
    write_log(@"");
    write_log(@"=== SCANNING MEMORY FOR HITBOX PATTERN ===");
    write_log(@"Looking for: 0x%08X (HEAD) followed by 0x%08X at +0x20", 
             firstValue, gHitboxes[1].original);
    write_log(@"");
    
    while (1) {
        count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(gTask, &address, &size, &depth,
                                                (vm_region_info_t)&info, &count);
        if (kr != KERN_SUCCESS) {
            if (kr == KERN_INVALID_ADDRESS) break;
            write_log(@"vm_region_recurse_64 error: %s", mach_error_string(kr));
            break;
        }
        
        regionCount++;
        
        // Only scan readable and writable regions (where data lives)
        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE)) {
            scannedRegions++;
            
            if (scannedRegions % 10 == 0) {
                write_log(@"Scanning region #%d: 0x%llX - 0x%llX (size: 0x%llX)", 
                         regionCount, (unsigned long long)address, 
                         (unsigned long long)(address + size), 
                         (unsigned long long)size);
            }
            
            // Scan for first value (HEAD)
            uint32_t buf = 0;
            for (vm_address_t addr = address; addr < address + size - 4; addr += 4) {
                if (!read_memory(addr, &buf, 4)) continue;
                
                // Found HEAD candidate
                if (buf == firstValue) {
                    // Check if TORSO_1 exists at +0x20
                    uint32_t secondBuf = 0;
                    vm_address_t secondAddr = addr + STEP_SIZE;
                    
                    if (read_memory(secondAddr, &secondBuf, 4) && 
                        secondBuf == gHitboxes[1].original) {
                        
                        write_log(@"");
                        write_log(@"🔍 Found potential HEAD at 0x%llX with TORSO_1 at 0x%llX", 
                                 (unsigned long long)addr, (unsigned long long)secondAddr);
                        
                        // Full verification of all 10 values
                        if (check_hitbox_pattern_at_address(addr)) {
                            return addr;
                        }
                    }
                }
            }
        }
        
        address += size;
    }
    
    write_log(@"");
    write_log(@"=== SCAN COMPLETE ===");
    write_log(@"Total regions: %d, Scanned RW regions: %d", regionCount, scannedRegions);
    return 0;
}

// ============================================================
// 7. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    write_log(@"");
    write_log(@"╔══════════════════════════════════════════════╗");
    write_log(@"║    BLACK RUSSIA HITBOX PATCHER v2.0        ║");
    write_log(@"║         Pattern-based search                ║");
    write_log(@"╚══════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    write_log(@"Task port: %d", gTask);
    
    // Scan memory
    vm_address_t found = scan_memory_for_pattern();
    
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
        write_log(@"  Original: 0x%08X (%.3f)", originalValue, originalFloat);
        write_log(@"  New:      0x%08X (%.3f)", newValue, newFloat);
        
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
            NSArray *windows = [UIApplication sharedApplication].windows;
            if (windows.count > 0) {
                window = windows.firstObject;
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
