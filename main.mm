// main.mm - Black Russia Hitbox Patcher (ARM64)
// Fixed with exact pattern from memory dump

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

// ============================================================
// 1. Original hitbox values (from actual memory dump)
// ============================================================
typedef struct {
    const char *name;
    uint32_t original;
    uint32_t patched;
    float originalFloat;
    float patchedFloat;
} HitboxValue;

static HitboxValue gHitboxes[] = {
    {"HEAD",        0x3E19999A, 0x3E99999A, 0.15f, 0.30f},      // x2
    {"TORSO_1",     0x3E4CCCCD, 0x3ECCCCCD, 0.20f, 0.40f},      // x2
    {"TORSO_2",     0x3E800000, 0x3F000000, 0.25f, 0.50f},      // x2
    {"MID",         0x3E800000, 0x3F000000, 0.25f, 0.50f},      // x2
    {"LEFTARM",     0x3E23D70A, 0x3EA3D70A, 0.16f, 0.32f},      // x2 (actual value from dump)
    {"RIGHTARM",    0x3E23D70A, 0x3EA3D70A, 0.16f, 0.32f},      // x2
    {"LEFTLEG_1",   0x3E4CCCCD, 0x3ECCCCCD, 0.20f, 0.40f},      // x2
    {"RIGHTLEG_1",  0x3E4CCCCD, 0x3ECCCCCD, 0.20f, 0.40f},      // x2
    {"LEFTLEG_2",   0x3E19999A, 0x3E99999A, 0.15f, 0.30f},      // x2
    {"RIGHTLEG_2",  0x3E19999A, 0x3E99999A, 0.15f, 0.30f}       // x2
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
// 6. Find blackrussia-client framework
// ============================================================
typedef struct {
    vm_address_t addr;
    vm_size_t size;
    const char *path;
    intptr_t slide;
} MemoryRegion;

static MemoryRegion find_blackrussia_client(void) {
    MemoryRegion result = {0, 0, NULL, 0};
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║              SEARCHING FOR blackrussia-client            ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    uint32_t imageCount = _dyld_image_count();
    write_log(@"📊 Total loaded images: %d", imageCount);
    write_log(@"");
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        
        NSString *imageName = [NSString stringWithUTF8String:name];
        
        if ([imageName containsString:@"blackrussia-client"] || 
            [imageName containsString:@"blackrussia-client.framework"]) {
            
            write_log(@"🎯 FOUND blackrussia-client!");
            write_log(@"  ┌─────────────────────────────────────────────");
            write_log(@"  │ Image index: %d", i);
            write_log(@"  │ Path: %s", name);
            write_log(@"  │ Header: 0x%llX", (unsigned long long)header);
            write_log(@"  │ Slide: 0x%lX", (unsigned long)slide);
            write_log(@"  └─────────────────────────────────────────────");
            write_log(@"");
            
            uint64_t dataSize = 0;
            char *dataPtr = getsectdatafromheader_64(header, "__DATA", "__data", &dataSize);
            
            if (dataPtr) {
                vm_address_t dataAddr = (vm_address_t)dataPtr + slide;
                result.addr = dataAddr;
                result.size = (vm_size_t)dataSize;
                result.path = name;
                result.slide = slide;
                
                write_log(@"📁 __DATA.__data section found:");
                write_log(@"  ┌─────────────────────────────────────────────");
                write_log(@"  │ Address: 0x%llX", (unsigned long long)dataAddr);
                write_log(@"  │ Size: 0x%llX (%llu bytes)", (unsigned long long)dataSize, (unsigned long long)dataSize);
                write_log(@"  │ Range: 0x%llX - 0x%llX", (unsigned long long)dataAddr, (unsigned long long)(dataAddr + dataSize));
                write_log(@"  └─────────────────────────────────────────────");
                write_log(@"");
                
                return result;
            }
        }
    }
    
    write_log(@"❌ blackrussia-client NOT FOUND!");
    return result;
}

// ============================================================
// 7. Search with tolerance
// ============================================================
static vm_address_t find_with_tolerance(vm_address_t start, vm_size_t size) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║      SCANNING WITH FLOAT TOLERANCE (%.3f)               ║", TOLERANCE);
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    write_log(@"📍 Search range: 0x%llX - 0x%llX", (unsigned long long)start, (unsigned long long)(start + size));
    write_log(@"");
    
    int checked = 0;
    int candidates = 0;
    
    for (vm_address_t addr = start; addr < start + size - 4; addr += 4) {
        checked++;
        if (checked % 100000 == 0) {
            write_log(@"  Scanned %d positions", checked);
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
        write_log(@"🔍 Candidate #%d at 0x%llX", candidates, (unsigned long long)addr);
        write_log(@"  HEAD:     0x%08X (%.3f) ✓", headVal, *(float*)&headVal);
        write_log(@"  TORSO_1:  0x%08X (%.3f) ✓", torsoVal, *(float*)&torsoVal);
        
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
                write_log(@"  %s:     0x%08X (%.3f) ✓ (diff: %.6f)", 
                         gHitboxes[i].name, val, actual, diff);
            } else {
                write_log(@"  %s:     0x%08X (%.3f) ✗ (expected: %.3f, diff: %.6f)", 
                         gHitboxes[i].name, val, actual, expected, diff);
                allMatch = NO;
                // Don't break, log all mismatches
            }
        }
        
        if (allMatch && matched == HITBOX_COUNT) {
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════╗");
            write_log(@"║     ✅ ALL %d HITBOXES MATCHED (with tolerance)!         ║", HITBOX_COUNT);
            write_log(@"╚═══════════════════════════════════════════════════════════╝");
            write_log(@"");
            write_log(@"📍 Found at: 0x%llX", (unsigned long long)addr);
            
            // Dump memory around found address
            write_log(@"");
            write_log(@"📄 Memory dump (32 bytes around each value):");
            for (int i = 0; i < HITBOX_COUNT; i++) {
                vm_address_t dumpAddr = addr + i * STEP_SIZE;
                write_log(@"  +0x%03X (%s): %@", i * STEP_SIZE, gHitboxes[i].name, hexDump(dumpAddr, 32));
            }
            
            return addr;
        }
    }
    
    write_log(@"");
    write_log(@"❌ Pattern not found. Scanned %d positions, found %d candidates", checked, candidates);
    return 0;
}

// ============================================================
// 8. Main patching logic
// ============================================================
static void patch_hitboxes(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║        BLACK RUSSIA HITBOX PATCHER v6.0                 ║");
    write_log(@"║        x2 Hitboxes (from actual memory dump)             ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    write_log(@"🔑 Task port: %d", gTask);
    write_log(@"");
    
    // Show what we're patching
    write_log(@"📋 Target values (x2):");
    for (int i = 0; i < HITBOX_COUNT; i++) {
        write_log(@"  %s: %.3f → %.3f", 
                 gHitboxes[i].name, 
                 gHitboxes[i].originalFloat, 
                 gHitboxes[i].patchedFloat);
    }
    write_log(@"");
    
    MemoryRegion brClient = find_blackrussia_client();
    
    if (brClient.addr == 0 || brClient.size == 0) {
        write_log(@"");
        write_log(@"❌ CRITICAL: blackrussia-client NOT FOUND!");
        show_notification(@"blackrussia-client not found.", @"Check HitBoxes.log");
        return;
    }
    
    vm_address_t found = find_with_tolerance(brClient.addr, brClient.size);
    
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
    write_log(@"║      BLACK RUSSIA HITBOX PATCHER v6.0 INJECTED          ║");
    write_log(@"║      x2 Hitboxes (from memory dump)                     ║");
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
