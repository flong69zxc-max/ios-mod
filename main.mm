// main.mm - Black Russia Hitbox Patcher (ARM64)
// Scans ALL memory regions for hitbox data

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>

// ============================================================
// 1. Original hitbox float values (little-endian hex)
// ============================================================
typedef struct {
    const char *name;
    uint32_t original[4];
    uint32_t patched[4];
    size_t len;
} HitboxPattern;

static HitboxPattern gPatterns[] = {
    {"HEAD",        {0x3E19999A}, {0x3E666666}, 1},
    {"TORSO_1",     {0x3E4CCCCD}, {0x3E99999A}, 1},
    {"TORSO_2",     {0x3E800000}, {0x3EC00000}, 1},
    {"MID",         {0x3E800000}, {0x3EC00000}, 1},
    {"LEFTARM",     {0x3E24E148}, {0x3E74E148}, 1},
    {"RIGHTARM",    {0x3E24E148}, {0x3E74E148}, 1},
    {"LEFTLEG_1",   {0x3E4CCCCD}, {0x3E99999A}, 1},
    {"RIGHTLEG_1",  {0x3E4CCCCD}, {0x3E99999A}, 1},
    {"LEFTLEG_2",   {0x3E19999A}, {0x3E666666}, 1},
    {"RIGHTLEG_2",  {0x3E19999A}, {0x3E666666}, 1}
};
#define PATTERN_COUNT (sizeof(gPatterns)/sizeof(gPatterns[0]))

// ============================================================
// 2. Logging helper
// ============================================================
static void write_log(NSString *message) {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths firstObject];
        NSString *savesPath = [documentsPath stringByAppendingPathComponent:@"saves"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:savesPath]) {
            [fileManager createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"HitBoxes.log"];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
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
// 4. Memory scanning helpers
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

// Check if pattern exists at address with step 0x20
static BOOL check_pattern_at_address(vm_address_t addr) {
    uint32_t buf = 0;
    
    // Check first pattern
    if (!read_memory(addr, &buf, 4) || buf != gPatterns[0].original[0]) {
        return NO;
    }
    
    // Check all 10 patterns with 0x20 step
    for (int i = 0; i < PATTERN_COUNT; i++) {
        vm_address_t checkAddr = addr + i * 0x20;
        if (!read_memory(checkAddr, &buf, 4)) {
            return NO;
        }
        if (buf != gPatterns[i].original[0]) {
            return NO;
        }
    }
    return YES;
}

// Scan all memory regions
static vm_address_t scan_all_memory(void) {
    vm_address_t address = 0;
    vm_size_t size = 0;
    vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    natural_t depth = 0;
    int regionCount = 0;
    
    write_log(@"Scanning ALL memory regions for hitbox pattern...");
    
    while (1) {
        // Reset count for each region
        count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(gTask, &address, &size, &depth,
                                                (vm_region_info_t)&info, &count);
        if (kr != KERN_SUCCESS) break;
        
        regionCount++;
        
        // Skip if no read permission
        if (!(info.protection & VM_PROT_READ)) {
            address += size;
            continue;
        }
        
        // Only scan regions that might contain data (RW, RWX, or RW-)
        if (info.protection & VM_PROT_WRITE) {
            if (regionCount % 50 == 0) {
                write_log([NSString stringWithFormat:@"Scanning region #%d: 0x%llX - 0x%llX (size: 0x%llX, prot: %d)",
                           regionCount, (unsigned long long)address, 
                           (unsigned long long)(address + size), 
                           (unsigned long long)size, info.protection]);
            }
            
            // Scan this region for the pattern
            vm_address_t found = 0;
            for (vm_address_t addr = address; addr < address + size - 4; addr += 4) {
                if (check_pattern_at_address(addr)) {
                    write_log([NSString stringWithFormat:@"Found pattern in region #%d at 0x%llX", 
                               regionCount, (unsigned long long)addr]);
                    return addr;
                }
            }
        }
        
        address += size;
    }
    
    write_log([NSString stringWithFormat:@"Scanned %d total regions, pattern not found", regionCount]);
    return 0;
}

// ============================================================
// 5. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    write_log(@"=== Hitbox Patcher Started ===");
    write_log(@"Black Russia Client - Hitbox Scanner");
    
    gTask = mach_task_self();
    
    // Scan all memory regions
    vm_address_t found = scan_all_memory();
    
    if (!found) {
        write_log(@"ERROR: Hitbox pattern not found in any memory region");
        show_notification(@"Hitboxes not found.", @"");
        return;
    }
    
    write_log([NSString stringWithFormat:@"Found hitboxes at: 0x%llX", (unsigned long long)found]);
    
    // Verify all patterns before patching
    BOOL allMatch = YES;
    for (int i = 0; i < PATTERN_COUNT; i++) {
        vm_address_t checkAddr = found + i * 0x20;
        uint32_t value = 0;
        if (!read_memory(checkAddr, &value, 4) || value != gPatterns[i].original[0]) {
            allMatch = NO;
            write_log([NSString stringWithFormat:@"VERIFY FAIL: %s at 0x%llX expected 0x%08X got 0x%08X",
                       gPatterns[i].name, (unsigned long long)checkAddr, 
                       gPatterns[i].original[0], value]);
            break;
        }
    }
    
    if (!allMatch) {
        write_log(@"ERROR: Pattern verification failed");
        show_notification(@"Hitboxes verification failed.", @"");
        return;
    }
    
    write_log(@"Pattern verified, applying patches...");
    
    // Patch all 10 values
    BOOL success = YES;
    for (int i = 0; i < PATTERN_COUNT; i++) {
        vm_address_t patchAddr = found + i * 0x20;
        uint32_t originalValue = 0;
        read_memory(patchAddr, &originalValue, 4);
        
        if (!write_memory(patchAddr, &gPatterns[i].patched[0], 4)) {
            success = NO;
            write_log([NSString stringWithFormat:@"ERROR: Failed to patch %s at 0x%llX", 
                       gPatterns[i].name, (unsigned long long)patchAddr]);
            break;
        }
        
        write_log([NSString stringWithFormat:@"Patched %s: 0x%08X -> 0x%08X at 0x%llX", 
                   gPatterns[i].name, originalValue, gPatterns[i].patched[0], 
                   (unsigned long long)patchAddr]);
    }
    
    if (success) {
        write_log(@"SUCCESS: All 10 hitboxes patched!");
        NSString *msg = [NSString stringWithFormat:@"Offset: 0x%llX", (unsigned long long)found];
        show_notification(@"Hitboxes patched successfully!", msg);
    } else {
        write_log(@"ERROR: Partial patch - some hitboxes failed");
        show_notification(@"Hitboxes patched partially.", @"");
    }
    
    write_log(@"=== Hitbox Patcher Finished ===\n");
}

// ============================================================
// 6. Notification display (UIAlertController)
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
// 7. Entry point
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    write_log(@"=== Hitbox Patcher Loaded ===");
    write_log(@"Black Russia Client - Injecting...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

// ============================================================
// 8. Dummy export
// ============================================================
extern "C" void __dummy_export(void) {}

// ============================================================
// Compile:
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//   -framework Foundation -framework UIKit \
//   -o mylib.dylib main.mm
// ============================================================
