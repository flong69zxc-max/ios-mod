// main.mm - Black Russia Hitbox Patcher (ARM64)
// Fixed forward declaration issue

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
// 2. Forward declaration
// ============================================================
static void show_notification(NSString *title, NSString *subtitle);

// ============================================================
// 3. Memory scanning helpers
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
// 4. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    gTask = mach_task_self();
    
    vm_address_t base = 0;
    vm_size_t size = 0;
    get_regions(&base, &size);
    
    if (base == 0 || size == 0) {
        show_notification(@"Hitboxes not found.", @"");
        return;
    }
    
    // Scan memory in chunks
    vm_address_t found = 0;
    vm_address_t scanAddr = base;
    vm_size_t chunkSize = 0x100000; // 1MB chunks
    
    while (scanAddr < base + size) {
        vm_size_t remaining = base + size - scanAddr;
        vm_size_t currentSize = remaining < chunkSize ? remaining : chunkSize;
        
        vm_address_t hit = find_pattern_with_step(scanAddr, currentSize,
                                                  gPatterns[0].original[0], 0x20);
        if (hit) {
            found = hit;
            break;
        }
        scanAddr += currentSize;
    }
    
    if (!found) {
        show_notification(@"Hitboxes not found.", @"");
        return;
    }
    
    // Patch all 10 values
    BOOL success = YES;
    for (int i = 0; i < PATTERN_COUNT; i++) {
        vm_address_t patchAddr = found + i * 0x20;
        if (!write_memory(patchAddr, &gPatterns[i].patched[0], 4)) {
            success = NO;
            break;
        }
    }
    
    if (success) {
        NSString *msg = [NSString stringWithFormat:@"Offset: 0x%llX", (unsigned long long)found];
        show_notification(@"Hitboxes patched successfully!", msg);
    } else {
        show_notification(@"Hitboxes patched partially.", @"");
    }
}

// ============================================================
// 5. Notification display (UIAlertController)
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
// 6. Entry point - called when library is loaded
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    // Wait a bit for the app to fully launch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

// ============================================================
// 7. Dummy export to avoid stripping
// ============================================================
extern "C" void __dummy_export(void) {}

// ============================================================
// Compile with:
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//   -framework Foundation -framework UIKit \
//   -o mylib.dylib main.mm
// ============================================================
