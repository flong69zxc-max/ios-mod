// main.mm - Black Russia Hitbox Patcher (ARM64)
// Dynamic library injection entry point

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <UserNotifications/UserNotifications.h>

// ============================================================
// 1. Original hitbox float values (little-endian hex)
// ============================================================
typedef struct {
    const char *name;
    uint32_t original[4];  // up to 4 bytes (float hex)
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
// 2. Memory scanning helpers
// ============================================================
static mach_port_t gTask = MACH_PORT_NULL;

// Read memory safely
static BOOL read_memory(vm_address_t addr, void *buffer, size_t size) {
    vm_size_t outSize = 0;
    kern_return_t kr = mach_vm_read_overwrite(gTask, addr, size,
                                              (vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

// Write memory safely
static BOOL write_memory(vm_address_t addr, const void *buffer, size_t size) {
    kern_return_t kr = mach_vm_write(gTask, addr, (vm_offset_t)buffer, size);
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

// ============================================================
// 3. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    gTask = mach_task_self();
    
    // Get the main executable's region (__TEXT segment)
    vm_address_t base = 0;
    vm_size_t size = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t kr = vm_region_recurse_64(gTask, &base, &size, &count,
                                            (vm_region_info_t)&info);
    if (kr != KERN_SUCCESS) {
        NSLog(@"Failed to get region");
        return;
    }
    
    // Scan from base to base+size (simplified - real would scan all regions)
    // For demo we scan a reasonable range (0x100000000 is 4GB)
    vm_address_t found = 0;
    for (vm_address_t addr = base; addr < base + size; addr += 0x1000) {
        vm_address_t hit = find_pattern_with_step(addr, 0x1000,
                                                  gPatterns[0].original[0], 0x20);
        if (hit) {
            found = hit;
            break;
        }
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
// 4. Notification display (UIAlertController / CFUserNotification)
// ============================================================
static void show_notification(NSString *title, NSString *subtitle) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        UIViewController *rootVC = keyWindow.rootViewController;
        
        if (rootVC) {
            // Use UIAlertController if we have a window
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:title
                message:subtitle
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        } else {
            // Fallback to CFUserNotification (works even without UI)
            CFUserNotificationDisplayAlert(
                0,  // timeout (0 = no timeout)
                kCFUserNotificationStopAlertLevel,
                NULL, NULL, NULL,
                (__bridge CFStringRef)title,
                (__bridge CFStringRef)subtitle,
                CFSTR("OK"), NULL, NULL,
                NULL
            );
        }
    });
}

// ============================================================
// 5. Entry point - called when library is loaded
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
// 6. Dummy export to avoid stripping
// ============================================================
extern "C" void __dummy_export(void) {}
