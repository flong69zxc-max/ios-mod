// main.mm - Black Russia Hitbox Patcher (ARM64)
// With logging to HitBoxes.log in saves folder

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
        // Get documents/saves directory
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths firstObject];
        NSString *savesPath = [documentsPath stringByAppendingPathComponent:@"saves"];
        
        // Create saves directory if it doesn't exist
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:savesPath]) {
            [fileManager createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"HitBoxes.log"];
        
        // Get current timestamp
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        
        // Format log entry
        NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        // Append to file
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } else {
            // Create new file
            [logEntry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        // Also log to console
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

// Read memory safely using vm_read_overwrite
static BOOL read_memory(vm_address_t addr, void *buffer, size_t size) {
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(gTask, addr, size,
                                         (vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

// Write memory safely using vm_write
static BOOL write_memory(vm_address_t addr, const void *buffer, size_t size) {
    kern_return_t kr = vm_write(gTask, addr, (vm_offset_t)buffer, size);
    return (kr == KERN_SUCCESS);
}

// Scan a region for a 4-byte pattern with step 0x20
static vm_address_t find_pattern_with_step(vm_address_t start, vm_size_t size,
                                           uint32_t pattern, size_t step) {
    uint32_t buf = 0;
    for (vm_address_t addr = start; addr < start + size - 4; addr += 4) {
        if (!read_memory(addr, &buf, 4)) continue;
        if (buf == pattern) {
            // Verify step to next occurrence
            BOOL valid = YES;
            for (int i = 1; i < PATTERN_COUNT; i++) {
                vm_address_t nextAddr = addr + i * step;
                uint32_t nextBuf = 0;
                if (!read_memory(nextAddr, &nextBuf, 4) || nextBuf != gPatterns[i].original[0]) {
                    valid = NO;
                    break;
                }
            }
            if (valid) return addr;
        }
    }
    return 0;
}

// Get all readable memory regions
static void get_regions(vm_address_t *outBase, vm_size_t *outSize) {
    vm_address_t address = 0;
    vm_size_t size = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    natural_t depth = 0;
    
    // Use vm_region_recurse_64 with proper parameters
    kern_return_t kr = vm_region_recurse_64(gTask, &address, &size, &depth,
                                            (vm_region_info_t)&info, &count);
    if (kr == KERN_SUCCESS) {
        *outBase = address;
        *outSize = size;
    } else {
        *outBase = 0;
        *outSize = 0;
    }
}

// ============================================================
// 5. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    write_log(@"=== Hitbox Patcher Started ===");
    
    gTask = mach_task_self();
    
    vm_address_t base = 0;
    vm_size_t size = 0;
    get_regions(&base, &size);
    
    write_log([NSString stringWithFormat:@"Base address: 0x%llX, Size: 0x%llX", 
               (unsigned long long)base, (unsigned long long)size]);
    
    if (base == 0 || size == 0) {
        write_log(@"ERROR: Failed to get memory region");
        show_notification(@"Hitboxes not found.", @"");
        return;
    }
    
    // Scan memory in chunks
    vm_address_t found = 0;
    vm_address_t scanAddr = base;
    vm_size_t chunkSize = 0x100000; // 1MB chunks
    int chunkCount = 0;
    
    write_log(@"Scanning memory for hitbox pattern...");
    
    while (scanAddr < base + size) {
        vm_size_t remaining = base + size - scanAddr;
        vm_size_t currentSize = remaining < chunkSize ? remaining : chunkSize;
        
        vm_address_t hit = find_pattern_with_step(scanAddr, currentSize,
                                                  gPatterns[0].original[0], 0x20);
        if (hit) {
            found = hit;
            write_log([NSString stringWithFormat:@"Pattern found at: 0x%llX (chunk %d)", 
                       (unsigned long long)hit, chunkCount]);
            break;
        }
        scanAddr += currentSize;
        chunkCount++;
        
        if (chunkCount % 10 == 0) {
            write_log([NSString stringWithFormat:@"Scanned %d chunks, current address: 0x%llX", 
                       chunkCount, (unsigned long long)scanAddr]);
        }
    }
    
    if (!found) {
        write_log(@"ERROR: Hitbox pattern not found in memory");
        show_notification(@"Hitboxes not found.", @"");
        return;
    }
    
    write_log([NSString stringWithFormat:@"Patching at address: 0x%llX", (unsigned long long)found]);
    
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
        write_log(@"SUCCESS: All hitboxes patched!");
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
        
        // Find a window (iOS 13+ compatible)
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
            // Fallback: try to get first window
            NSArray *windows = [UIApplication sharedApplication].windows;
            if (windows.count > 0) {
                window = windows.firstObject;
            }
        }
        
        UIViewController *rootVC = window.rootViewController;
        
        if (rootVC) {
            // Use UIAlertController
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:title
                message:subtitle
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        } else {
            // Fallback to NSLog if no UI available
            NSLog(@"%@: %@", title, subtitle);
        }
    });
}

// ============================================================
// 7. Entry point - called when library is loaded
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    write_log(@"=== Hitbox Patcher Loaded ===");
    write_log(@"Waiting 2 seconds for app to initialize...");
    
    // Wait a bit for the app to fully launch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

// ============================================================
// 8. Dummy export to avoid stripping
// ============================================================
extern "C" void __dummy_export(void) {}

// ============================================================
// Compile with:
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//   -framework Foundation -framework UIKit \
//   -o mylib.dylib main.mm
// ============================================================
