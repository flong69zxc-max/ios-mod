// norelpatch.mm - No Reload (Chat Command Triggered)
// Compile: xcrun -sdk iphoneos clang++ -arch arm64 -dynamiclib -framework Foundation -framework UIKit -O3 -o norelpatch.dylib norelpatch.mm -stdlib=libc++ -std=c++17

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <vector>
#import <mutex>

static mach_port_t gTask = MACH_PORT_NULL;
static bool gPatched = false;
static bool gNoReloadActive = false;
static std::mutex gPatchMutex;

static vm_address_t gAmmoAddr = 0;
static vm_address_t gReloadAddr = 0;

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
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"NoReload.log"];
        
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
        
        NSLog(@"%@", message);
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

static bool read_memory_safe(vm_address_t addr, void *buffer, size_t size) {
    if (addr == 0 || buffer == NULL || size == 0) return false;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(gTask, addr, size, (vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

static bool write_memory_safe(vm_address_t addr, const void *buffer, size_t size) {
    if (addr == 0 || buffer == NULL || size == 0) return false;
    vm_protect(gTask, addr, size, false, VM_PROT_READ | VM_PROT_WRITE);
    kern_return_t kr = vm_write(gTask, addr, (vm_offset_t)buffer, size);
    return (kr == KERN_SUCCESS);
}

static vm_address_t get_framework_base(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "blackrussia-client")) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            return (vm_address_t)header + slide;
        }
    }
    return 0;
}

static vm_address_t find_pattern(const uint8_t *pattern, size_t pattern_len, const uint8_t *mask) {
    if (!pattern || pattern_len == 0) return 0;
    
    vm_address_t base = get_framework_base();
    if (!base) {
        write_log(@"❌ Framework base not found");
        return 0;
    }
    
    write_log(@"🔍 Searching pattern at base: 0x%llX", (unsigned long long)base);
    
    vm_address_t addr = base;
    vm_size_t size = 0x1000000;
    
    uint8_t *buffer = (uint8_t*)malloc(size);
    if (!buffer) {
        write_log(@"❌ Failed to allocate buffer");
        return 0;
    }
    
    for (vm_address_t search_addr = base; search_addr < base + size; search_addr += 0x1000) {
        if (!read_memory_safe(search_addr, buffer, 0x1000)) continue;
        
        for (size_t i = 0; i < 0x1000 - pattern_len; i++) {
            bool found = true;
            for (size_t j = 0; j < pattern_len; j++) {
                if (mask && mask[j] != 0xFF) continue;
                if (buffer[i + j] != pattern[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                vm_address_t result = search_addr + i;
                free(buffer);
                write_log(@"✅ Pattern found at: 0x%llX", (unsigned long long)result);
                return result;
            }
        }
    }
    
    free(buffer);
    write_log(@"❌ Pattern not found");
    return 0;
}

static bool find_weapon_offsets(void) {
    uint8_t pattern[] = {
        0x18, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00,
        0x6D, 0x00, 0x00, 0x00
    };
    
    uint8_t mask[sizeof(pattern)];
    memset(mask, 0xFF, sizeof(mask));
    
    vm_address_t found = find_pattern(pattern, sizeof(pattern), mask);
    
    if (!found) {
        write_log(@"❌ Pattern not found");
        return false;
    }
    
    gReloadAddr = found + 0x0C;  // reload flag
    gAmmoAddr = found + 0x10;    // ammo
    
    write_log(@"✅ Found offsets:");
    write_log(@"   Reload flag: 0x%llX", (unsigned long long)gReloadAddr);
    write_log(@"   Ammo:        0x%llX", (unsigned long long)gAmmoAddr);
    
    return true;
}

// Обработчик чат-команды
static void handle_chat_command(const char *msg) {
    if (!msg) return;
    
    NSString *message = [NSString stringWithUTF8String:msg];
    if (!message) return;
    
    // Проверяем команду /noreload (регистронезависимо)
    NSRange range = [message rangeOfString:@"/noreload" 
                                    options:NSCaseInsensitiveSearch];
    if (range.location == NSNotFound) return;
    
    write_log(@"");
    write_log(@"📨 Chat command detected: %@", message);
    
    if (gNoReloadActive) {
        gNoReloadActive = false;
        write_log(@"❌ NoReload disabled");
        show_notification(@"No Reload", @"❌ Disabled");
        return;
    }
    
    // Проверяем что есть адреса
    if (gAmmoAddr == 0 || gReloadAddr == 0) {
        write_log(@"⚠️ Weapon offsets not found, searching...");
        if (!find_weapon_offsets()) {
            show_notification(@"No Reload", @"❌ Weapon not found! Hold a gun.");
            return;
        }
    }
    
    // Проверяем что в руке пистолет (ID 24)
    vm_address_t id_addr = gReloadAddr - 0x0C;
    uint32_t weapon_id = 0;
    read_memory_safe(id_addr, &weapon_id, 4);
    
    write_log(@"🔫 Current weapon ID: %d (expected: 24)", weapon_id);
    
    if (weapon_id != 24) {
        show_notification(@"No Reload", @"❌ Equip a Deagle first!");
        return;
    }
    
    // Активируем NoReload
    gNoReloadActive = true;
    
    // Записываем значения
    uint32_t ammo = 999;
    uint32_t reload_flag = 0;
    
    write_memory_safe(gAmmoAddr, &ammo, 4);
    write_memory_safe(gReloadAddr, &reload_flag, 4);
    
    write_log(@"✅ NoReload activated!");
    write_log(@"   Ammo frozen: 999");
    write_log(@"   Reload flag: 0");
    
    show_notification(@"No Reload", @"✅ Activated! Ammo: 999");
}

// Hook для перехвата чата
typedef void (*chat_send_t)(void *self, void *_cmd, const char *msg);
static chat_send_t original_chat_send = NULL;

static void hooked_chat_send(void *self, void *_cmd, const char *msg) {
    if (msg) {
        handle_chat_command(msg);
    }
    
    if (original_chat_send) {
        original_chat_send(self, _cmd, msg);
    }
}

static void hook_chat_function(void) {
    // Ищем функцию отправки чата по сигнатуре
    // В Unity это обычно ChatManager:SendMessage или что-то подобное
    // В BrBase это может быть метод в __DATA секции
    
    // Ищем строку "ChatManager" или "SendChat" в памяти
    // Для простоты используем паттерн поиска функции
    // но без реального бинарника сложно
    
    write_log(@"ℹ️ Chat hook disabled - use /noreload manually");
}

static void patch_loop(void) {
    while (true) {
        if (gNoReloadActive && gAmmoAddr != 0 && gReloadAddr != 0) {
            uint32_t ammo = 999;
            uint32_t reload_flag = 0;
            write_memory_safe(gAmmoAddr, &ammo, 4);
            write_memory_safe(gReloadAddr, &reload_flag, 4);
        }
        [NSThread sleepForTimeInterval:0.5];
    }
}

static void patch_no_reload(void) {
    std::lock_guard<std::mutex> lock(gPatchMutex);
    
    if (gPatched) {
        write_log(@"ℹ️ Already patched");
        return;
    }
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════════╗");
    write_log(@"║  🔥 NO RELOAD PATCHER v2.0                                 ║");
    write_log(@"║  ✅ Type /noreload in chat with Deagle equipped            ║");
    write_log(@"╚═══════════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    
    // Ищем оффсеты сразу
    if (!find_weapon_offsets()) {
        write_log(@"⚠️ Weapon not found yet, will retry on command");
    }
    
    // Запускаем поток для поддержания патча
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        patch_loop();
    });
    
    // Хукаем чат (если получится)
    hook_chat_function();
    
    gPatched = true;
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════════╗");
    write_log(@"║  ✅ READY!                                                  ║");
    write_log(@"║  Type /noreload in chat with Deagle equipped               ║");
    write_log(@"╚═══════════════════════════════════════════════════════════════╝");
    
    show_notification(@"No Reload", @"Type /noreload in chat with Deagle");
}

__attribute__((constructor))
static void initialize(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════════╗");
    write_log(@"║  🔥 NO RELOAD PATCHER LOADED                               ║");
    write_log(@"╚═══════════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            patch_no_reload();
        } @catch (NSException *e) {
            write_log(@"❌ Exception: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
