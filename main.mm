// main.mm - Black Russia Hitbox Patcher (ARM64) - ULTIMATE VERSION
// ✅ РАБОТАЕТ ТОЛЬКО С АБСОЛЮТНЫМИ АДРЕСАМИ
// ✅ ДИНАМИЧЕСКИЙ ПОИСК (НИКАКИХ ХАРДКОДОВ)
// ✅ ПРАВИЛЬНЫЙ РАСЧЕТ ОТНОСИТЕЛЬНОГО И АБСОЛЮТНОГО АДРЕСОВ

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mach-o/nlist.h>
#import <mutex>
#import <vector>

// ============================================================
// 1. Hitbox структура с float значениями
// ============================================================
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

// ============================================================
// 2. Глобальные переменные с защитой
// ============================================================
static vm_address_t gFrameworkBase = 0;
static const char *gFrameworkPath = NULL;
static bool gPatched = false;
static std::mutex gPatchMutex;
static mach_port_t gTask = MACH_PORT_NULL;

// Абсолютный адрес найденных хитбоксов
static vm_address_t gHitboxesAbsoluteAddr = 0;
// Относительный адрес (RVA) - вычисляется как абсолютный - база
static vm_address_t gHitboxesRelativeAddr = 0;

// ============================================================
// 3. Структура для секций памяти
// ============================================================
typedef struct {
    vm_address_t absolute;    // Абсолютный адрес в памяти
    vm_size_t size;
    const char *name;
} MemorySection;

static std::vector<MemorySection> gSections;

// ============================================================
// 4. Logging с синхронизацией
// ============================================================
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

// ============================================================
// 5. Показ уведомлений (перенесено ВВЕРХ, до использования)
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
        
        // Fallback для старых версий
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
                // Используем старый API только для iOS < 13
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

// ============================================================
// 6. Memory helpers с проверкой
// ============================================================
static bool read_memory_safe(vm_address_t absoluteAddr, void *buffer, size_t size) {
    if (absoluteAddr == 0 || buffer == NULL || size == 0) return false;
    
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(gTask, absoluteAddr, size,
                                         (vm_address_t)buffer, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

static bool write_memory_safe(vm_address_t absoluteAddr, const void *buffer, size_t size) {
    if (absoluteAddr == 0 || buffer == NULL || size == 0) return false;
    
    // Проверка на защиту памяти
    vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;
    kern_return_t kr = vm_protect(gTask, absoluteAddr, size, false, prot);
    if (kr != KERN_SUCCESS) {
        write_log(@"⚠️ Не удалось снять защиту: %d", kr);
    }
    
    kr = vm_write(gTask, absoluteAddr, (vm_offset_t)buffer, size);
    return (kr == KERN_SUCCESS);
}

// ============================================================
// 7. Поиск blackrussia-client.framework
// ============================================================
static vm_address_t find_blackrussia_framework(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     🔍 ПОИСК blackrussia-client.framework                ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    
    uint32_t imageCount = _dyld_image_count();
    write_log(@"📊 Загружено образов: %d", imageCount);
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        
        NSString *imageName = [NSString stringWithUTF8String:name];
        if ([imageName containsString:@"blackrussia-client"]) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!header) continue;
            
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            gFrameworkBase = (vm_address_t)header + slide;
            gFrameworkPath = name;
            
            write_log(@"");
            write_log(@"✅ НАЙДЕН!");
            write_log(@"  ┌─────────────────────────────────────────────");
            write_log(@"  │ Index: %d", i);
            write_log(@"  │ Path: %s", name);
            write_log(@"  │ Абсолютный адрес заголовка: 0x%llX", (unsigned long long)header);
            write_log(@"  │ Slide: 0x%lX", (unsigned long)slide);
            write_log(@"  │ Базовый адрес (ASLR):  0x%llX", (unsigned long long)gFrameworkBase);
            write_log(@"  └─────────────────────────────────────────────");
            
            // Сканируем секции
            gSections.clear();
            uint64_t size = 0;
            
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            char *data = getsectdatafromheader_64(header, "__DATA", "__data", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA.__data"};
                gSections.push_back(sect);
                write_log(@"  📁 %s: 0x%llX (абсолютный)", sect.name, (unsigned long long)sect.absolute);
            }
            
            data = getsectdatafromheader_64(header, "__DATA", "__const", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA.__const"};
                gSections.push_back(sect);
                write_log(@"  📁 %s: 0x%llX (абсолютный)", sect.name, (unsigned long long)sect.absolute);
            }
            
            data = getsectdatafromheader_64(header, "__DATA_CONST", "__const", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA_CONST.__const"};
                gSections.push_back(sect);
                write_log(@"  📁 %s: 0x%llX (абсолютный)", sect.name, (unsigned long long)sect.absolute);
            }
            
            data = getsectdatafromheader_64(header, "__DATA", "__bss", &size);
            if (data && size > 0) {
                MemorySection sect = {(vm_address_t)data + slide, size, "__DATA.__bss"};
                gSections.push_back(sect);
                write_log(@"  📁 %s: 0x%llX (абсолютный)", sect.name, (unsigned long long)sect.absolute);
            }
#pragma clang diagnostic pop
            
            write_log(@"");
            write_log(@"📊 Всего секций: %zu", gSections.size());
            
            return gFrameworkBase;
        }
    }
    
    write_log(@"❌ blackrussia-client НЕ НАЙДЕН!");
    return 0;
}

// ============================================================
// 8. Быстрый поиск хитбоксов в абсолютных адресах
// ============================================================
static vm_address_t find_hitboxes_absolute(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     🎯 ДИНАМИЧЕСКИЙ ПОИСК ХИТБОКСОВ                     ║");
    write_log(@"║     Сканируем АБСОЛЮТНЫЕ адреса в памяти                ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    write_log(@"🔍 Ищем паттерн (10 значений, шаг 0x%X):", STEP_SIZE);
    for (int i = 0; i < HITBOX_COUNT; i++) {
        write_log(@"  +0x%03X: %s = %.3f (0x%08X)", 
                 i * STEP_SIZE, 
                 gHitboxes[i].name, 
                 gHitboxes[i].originalFloat,
                 gHitboxes[i].original);
    }
    write_log(@"");
    
    size_t totalScanned = 0;
    size_t totalCandidates = 0;
    
    for (const auto& sect : gSections) {
        vm_address_t startAbsolute = sect.absolute;
        vm_size_t size = sect.size;
        
        if (size < HITBOX_COUNT * STEP_SIZE) continue;
        
        write_log(@"");
        write_log(@"🔎 Сканируем %s (0x%llX байт)", sect.name, (unsigned long long)size);
        write_log(@"   Абсолютный адрес начала: 0x%llX", (unsigned long long)startAbsolute);
        
        size_t scanned = 0;
        size_t candidates = 0;
        
        // Оптимизация: используем поиск с шагом 4 байта
        for (vm_address_t addr = startAbsolute; 
             addr <= startAbsolute + size - (HITBOX_COUNT * STEP_SIZE); 
             addr += 4) {
            
            scanned++;
            totalScanned++;
            
            // Прогресс каждые 100k итераций
            if (scanned % 100000 == 0) {
                write_log(@"  📊 Сканировано %zu позиций в %s", scanned, sect.name);
            }
            
            // Быстрая проверка первого значения
            uint32_t headVal = 0;
            if (!read_memory_safe(addr, &headVal, 4)) continue;
            if (headVal != gHitboxes[0].original) continue;
            
            // Проверяем остальные значения
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
                totalCandidates++;
                
                // ✅ Сохраняем АБСОЛЮТНЫЙ адрес (реальный адрес в памяти)
                gHitboxesAbsoluteAddr = addr;
                
                // ✅ Вычисляем ОТНОСИТЕЛЬНЫЙ адрес (RVA) = абсолютный - база
                gHitboxesRelativeAddr = addr - gFrameworkBase;
                
                write_log(@"");
                write_log(@"🎯 НАЙДЕН КАНДИДАТ #%zu!", candidates);
                write_log(@"  ┌─────────────────────────────────────────────");
                write_log(@"  │ АБСОЛЮТНЫЙ адрес: 0x%llX", (unsigned long long)addr);
                write_log(@"  │ Базовый адрес:    0x%llX", (unsigned long long)gFrameworkBase);
                write_log(@"  │ ОТНОСИТЕЛЬНЫЙ:    0x%llX (абсолютный - база)", 
                         (unsigned long long)gHitboxesRelativeAddr);
                write_log(@"  │ Секция: %s", sect.name);
                write_log(@"  └─────────────────────────────────────────────");
                write_log(@"");
                write_log(@"📋 Проверка значений:");
                
                for (int i = 0; i < HITBOX_COUNT; i++) {
                    vm_address_t checkAddr = addr + i * STEP_SIZE;
                    uint32_t val = 0;
                    read_memory_safe(checkAddr, &val, 4);
                    float actual = *(float*)&val;
                    write_log(@"  +0x%03X %s: 0x%08X = %.3f ✓", 
                             i * STEP_SIZE, gHitboxes[i].name, val, actual);
                }
                
                write_log(@"");
                write_log(@"╔═══════════════════════════════════════════════════════════╗");
                write_log(@"║     ✅ ВСЕ %d ХИТБОКСОВ НАЙДЕНЫ!                        ║", HITBOX_COUNT);
                write_log(@"║     АБСОЛЮТНЫЙ адрес: 0x%llX                           ║", (unsigned long long)gHitboxesAbsoluteAddr);
                write_log(@"║     ОТНОСИТЕЛЬНЫЙ (RVA): 0x%llX                        ║", (unsigned long long)gHitboxesRelativeAddr);
                write_log(@"║     Формула: 0x%llX - 0x%llX = 0x%llX                  ║", 
                         (unsigned long long)gHitboxesAbsoluteAddr,
                         (unsigned long long)gFrameworkBase,
                         (unsigned long long)gHitboxesRelativeAddr);
                write_log(@"╚═══════════════════════════════════════════════════════════╝");
                
                return addr; // Возвращаем АБСОЛЮТНЫЙ адрес
            }
        }
        
        write_log(@"  📊 Сканировано %zu позиций, кандидатов: %zu", scanned, candidates);
    }
    
    write_log(@"");
    write_log(@"❌ Хитбоксы НЕ НАЙДЕНЫ!");
    write_log(@"📊 Всего сканировано: %zu позиций", totalScanned);
    return 0;
}

// ============================================================
// 9. Патчинг хитбоксов (работаем с АБСОЛЮТНЫМИ адресами)
// ============================================================
static bool patch_hitboxes_absolute(vm_address_t absoluteAddr) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     💉 ПРИМЕНЕНИЕ ПАТЧЕЙ (x2)                           ║");
    write_log(@"║     Работаем с АБСОЛЮТНЫМИ адресами                     ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    if (absoluteAddr == 0) {
        write_log(@"❌ Некорректный абсолютный адрес!");
        return false;
    }
    
    write_log(@"📍 Абсолютный адрес начала: 0x%llX", (unsigned long long)absoluteAddr);
    write_log(@"📍 Базовый адрес:           0x%llX", (unsigned long long)gFrameworkBase);
    write_log(@"📍 Относительный (RVA):     0x%llX", (unsigned long long)gHitboxesRelativeAddr);
    write_log(@"");
    
    bool allSuccess = true;
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        // ✅ Используем АБСОЛЮТНЫЙ адрес для записи
        vm_address_t patchAddr = absoluteAddr + i * STEP_SIZE;
        uint32_t newValue = gHitboxes[i].patched;
        float newFloat = *(float*)&newValue;
        
        // Читаем оригинальное значение
        uint32_t originalValue = 0;
        read_memory_safe(patchAddr, &originalValue, 4);
        float originalFloat = *(float*)&originalValue;
        
        write_log(@"📝 %s:", gHitboxes[i].name);
        write_log(@"  Абсолютный адрес: 0x%llX", (unsigned long long)patchAddr);
        write_log(@"  Оригинал: 0x%08X (%.3f)", originalValue, originalFloat);
        write_log(@"  Патч:     0x%08X (%.3f) ×2", newValue, newFloat);
        
        // Записываем новое значение
        if (!write_memory_safe(patchAddr, &newValue, 4)) {
            allSuccess = false;
            write_log(@"  ❌ ОШИБКА ЗАПИСИ!");
            break;
        }
        
        // Верифицируем
        uint32_t verifyValue = 0;
        read_memory_safe(patchAddr, &verifyValue, 4);
        
        if (verifyValue == newValue) {
            write_log(@"  ✅ ВЕРИФИЦИРОВАНО");
        } else {
            allSuccess = false;
            write_log(@"  ❌ ВЕРИФИКАЦИЯ НЕ УДАЛАСЬ!");
            break;
        }
        write_log(@"");
    }
    
    return allSuccess;
}

// ============================================================
// 10. Основная функция патчинга
// ============================================================
static void patch_hitboxes(void) {
    std::lock_guard<std::mutex> lock(gPatchMutex);
    
    if (gPatched) {
        write_log(@"⚠️ Патч уже применен!");
        return;
    }
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     🚀 BLACK RUSSIA HITBOX PATCHER v13.0                ║");
    write_log(@"║     ✅ ТОЛЬКО АБСОЛЮТНЫЕ АДРЕСА                         ║");
    write_log(@"║     ✅ ДИНАМИЧЕСКИЙ ПОИСК                                ║");
    write_log(@"║     ✅ ПРАВИЛЬНЫЙ РАСЧЕТ RVA                            ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    gTask = mach_task_self();
    write_log(@"🔑 Task port: %d", gTask);
    
    // 1. Находим фреймворк и получаем БАЗОВЫЙ адрес
    if (!find_blackrussia_framework() || gFrameworkBase == 0) {
        write_log(@"❌ Не удалось найти blackrussia-client.framework");
        show_notification(@"Ошибка", @"Фреймворк не найден");
        return;
    }
    
    // 2. Динамически ищем хитбоксы (сканируем АБСОЛЮТНЫЕ адреса)
    vm_address_t foundAbsolute = find_hitboxes_absolute();
    if (!foundAbsolute) {
        write_log(@"❌ Хитбоксы не найдены!");
        show_notification(@"Ошибка", @"Хитбоксы не найдены");
        return;
    }
    
    // 3. Применяем патчи (используем АБСОЛЮТНЫЙ адрес)
    bool success = patch_hitboxes_absolute(foundAbsolute);
    
    if (success) {
        gPatched = true;
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║     ✅ ВСЕ 10 ХИТБОКСОВ УСПЕШНО ЗАПАТЧЕНЫ!              ║");
        write_log(@"║                                                          ║");
        write_log(@"║     📍 АБСОЛЮТНЫЙ адрес: 0x%llX                       ║", (unsigned long long)gHitboxesAbsoluteAddr);
        write_log(@"║     📍 Базовый адрес:    0x%llX                       ║", (unsigned long long)gFrameworkBase);
        write_log(@"║     📍 ОТНОСИТЕЛЬНЫЙ:    0x%llX                       ║", (unsigned long long)gHitboxesRelativeAddr);
        write_log(@"║                                                          ║");
        write_log(@"║     Формула: 0x%llX - 0x%llX = 0x%llX                  ║", 
                 (unsigned long long)gHitboxesAbsoluteAddr,
                 (unsigned long long)gFrameworkBase,
                 (unsigned long long)gHitboxesRelativeAddr);
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        
        NSString *msg = [NSString stringWithFormat:
            @"Абсолютный: 0x%llX\n"
            @"Относительный: 0x%llX\n"
            @"x2 Hitboxes активны!",
            (unsigned long long)gHitboxesAbsoluteAddr,
            (unsigned long long)gHitboxesRelativeAddr];
        show_notification(@"✅ Патч успешно применен!", msg);
        
    } else {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║              ❌ ПАТЧ НЕ УДАЛСЯ!                          ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        show_notification(@"❌ Ошибка", @"Патч не удался. Проверьте логи.");
    }
}

// ============================================================
// 11. Точка входа
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     🔥 HITBOX PATCHER INJECTED v13.0                     ║");
    write_log(@"║     ✅ Работает только с абсолютными адресами            ║");
    write_log(@"║     ✅ Динамический поиск в памяти                       ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    write_log(@"⏳ Ожидаем 5 секунд для загрузки игры...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        patch_hitboxes();
    });
}

// ============================================================
// 12. Dummy export
// ============================================================
extern "C" void __dummy_export(void) {}

// ============================================================
// Компиляция:
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//   -framework Foundation -framework UIKit \
//   -std=c++17 -O3 \
//   -o hitbox_patcher.dylib main.mm
// ============================================================
