// BlackRussiaHitbox.dylib
// Компиляция: clang++ -dynamiclib -o BlackRussiaHitbox.dylib main.cpp -framework Foundation -framework UIKit -framework CoreGraphics -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -miphoneos-version-min=14.0 -std=c++17 -O2

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <vector>
#include <string>
#include <mutex>
#include <fstream>
#include <sstream>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ==================== КОНФИГУРАЦИЯ ====================
#define HITBOX_COUNT 10
#define HITBOX_STEP 0x20
#define MAX_SLIDER_VALUE 10.0f
#define MIN_SLIDER_VALUE 0.5f

// Имена частей тела
static const char* bodyPartNames[] = {
    "HEAD",
    "TORSO_1",
    "TORSO_2",
    "MID",
    "LEFTARM",
    "RIGHTARM",
    "LEFTLEG_1",
    "RIGHTLEG_1",
    "LEFTLEG_2",
    "RIGHTLEG_2"
};

// Стоковые значения
static float stockValues[HITBOX_COUNT] = {
    0.15f, 0.20f, 0.25f, 0.25f, 0.16f,
    0.16f, 0.20f, 0.20f, 0.15f, 0.15f
};

// Сигнатуры для поиска (первые 3 значения + следующие 2 для верификации)
static const uint8_t signatureBytes[] = {
    0x9A, 0x99, 0x19, 0x3E,  // 0.15 HEAD
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20 TORSO_1
    0x00, 0x00, 0x80, 0x3E,  // 0.25 TORSO_2
    0x00, 0x00, 0x80, 0x3E,  // 0.25 MID
    0x48, 0xE1, 0x24, 0x3E   // 0.16 LEFTARM
};

// ==================== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ====================
static uintptr_t g_headAddress = 0;        // Адрес HEAD в памяти
static float g_currentValues[HITBOX_COUNT]; // Текущие значения
static bool g_menuVisible = false;          // Видимость меню
static bool g_initialized = false;          // Флаг инициализации
static std::mutex g_mutex;                  // Мьютекс для потокобезопасности
static void* g_imguiCtx = nullptr;          // Контекст ImGui (заглушка)

// Файл для кэширования
static NSString* getCachePath() {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:@"br_hitbox_cache.dat"];
}

// ==================== БЕЗОПАСНАЯ ЗАПИСЬ В ПАМЯТЬ ====================
bool safeWriteFloat(uintptr_t addr, float value) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)addr, 
                                   sizeof(float), FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) return false;
    
    *(float*)addr = value;
    
    vm_protect(mach_task_self(), (vm_address_t)addr, 
               sizeof(float), FALSE, VM_PROT_READ);
    return true;
}

bool safeWriteAllHitboxes(float values[HITBOX_COUNT]) {
    if (g_headAddress == 0) return false;
    
    // Меняем защиту на всём блоке
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)g_headAddress,
                                  HITBOX_COUNT * HITBOX_STEP, FALSE, 
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) return false;
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        *(float*)(g_headAddress + i * HITBOX_STEP) = values[i];
    }
    
    vm_protect(mach_task_self(), (vm_address_t)g_headAddress,
               HITBOX_COUNT * HITBOX_STEP, FALSE, VM_PROT_READ);
    
    memcpy(g_currentValues, values, sizeof(float) * HITBOX_COUNT);
    return true;
}

// ==================== ПОИСК АДРЕСА ====================

// Метод 1: Поиск по сигнатуре
uintptr_t patternScan(const uint8_t* data, size_t dataSize, 
                      const uint8_t* pattern, size_t patternSize) {
    for (size_t i = 0; i < dataSize - patternSize; i++) {
        if (memcmp(data + i, pattern, patternSize) == 0) {
            return (uintptr_t)(data + i);
        }
    }
    return 0;
}

// Метод 2: Поиск по диапазону значений с шагом
uintptr_t rangeScan(uintptr_t start, uintptr_t end) {
    for (uintptr_t addr = start; addr < end - (HITBOX_COUNT * HITBOX_STEP); addr += 4) {
        // Проверяем первое значение (0.15 ± 0.01)
        float v0 = *(float*)addr;
        if (fabsf(v0 - stockValues[0]) > 0.01f) continue;
        
        // Проверяем второе через 0x20
        float v1 = *(float*)(addr + HITBOX_STEP);
        if (fabsf(v1 - stockValues[1]) > 0.01f) continue;
        
        // Проверяем третье
        float v2 = *(float*)(addr + 2 * HITBOX_STEP);
        if (fabsf(v2 - stockValues[2]) > 0.01f) continue;
        
        // Верификация логики: HEAD(0.15) < TORSO_1(0.20) < TORSO_2(0.25)
        if (v0 < v1 && v1 <= v2) {
            // Проверяем все 10 значений
            bool valid = true;
            for (int i = 0; i < HITBOX_COUNT; i++) {
                float val = *(float*)(addr + i * HITBOX_STEP);
                if (val < 0.05f || val > 0.50f) {
                    valid = false;
                    break;
                }
            }
            if (valid) return addr;
        }
    }
    return 0;
}

// Основная функция поиска
uintptr_t findHitboxAddress() {
    // Ищем библиотеку blackrussia-client
    uint32_t count = _dyld_image_count();
    const struct mach_header* header = nullptr;
    intptr_t slide = 0;
    
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (strstr(name, "blackrussia-client")) {
            header = _dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    
    if (!header) {
        NSLog(@"[BRHitbox] Библиотека не найдена");
        return 0;
    }
    
    // Собираем все сегменты для сканирования
    struct SearchRegion {
        uintptr_t start;
        uintptr_t end;
    };
    std::vector<SearchRegion> regions;
    
    // Сегменты библиотеки
    uintptr_t libStart = 0, libEnd = 0;
    struct mach_header_64* h64 = (struct mach_header_64*)header;
    struct load_command* lc = (struct load_command*)((char*)h64 + sizeof(struct mach_header_64));
    
    for (uint32_t i = 0; i < h64->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64* seg = (struct segment_command_64*)lc;
            uintptr_t start = seg->vmaddr + slide;
            uintptr_t end = start + seg->vmsize;
            
            regions.push_back({start, end});
            
            if (libStart == 0 || start < libStart) libStart = start;
            if (end > libEnd) libEnd = end;
        }
        lc = (struct load_command*)((char*)lc + lc->cmdsize);
    }
    
    NSLog(@"[BRHitbox] Сканирую %zu регионов, диапазон 0x%lx-0x%lx", 
          regions.size(), libStart, libEnd);
    
    // Метод 1: Pattern scan по всем регионам
    for (auto& region : regions) {
        size_t size = region.end - region.start;
        uintptr_t result = patternScan((uint8_t*)region.start, size, 
                                       signatureBytes, sizeof(signatureBytes));
        if (result != 0) {
            // Верифицируем что нашли именно структуру
            float* vals = (float*)result;
            if (fabsf(vals[0] - 0.15f) < 0.01f &&
                fabsf(vals[8] - 0.20f) < 0.01f) { // Проверяем TORSO_1 через 0x20*8
                NSLog(@"[BRHitbox] Найдено сигнатурой: 0x%lx", result);
                return result;
            }
        }
    }
    
    // Метод 2: Range scan
    for (auto& region : regions) {
        uintptr_t result = rangeScan(region.start, region.end);
        if (result != 0) {
            NSLog(@"[BRHitbox] Найдено range scan: 0x%lx", result);
            return result;
        }
    }
    
    NSLog(@"[BRHitbox] Адрес не найден");
    return 0;
}

// ==================== КЭШИРОВАНИЕ ====================
void saveCache(uintptr_t addr, float values[HITBOX_COUNT]) {
    NSString* path = getCachePath();
    NSMutableData* data = [NSMutableData dataWithLength:sizeof(uintptr_t) + sizeof(float) * HITBOX_COUNT];
    
    uint8_t* bytes = (uint8_t*)data.mutableBytes;
    memcpy(bytes, &addr, sizeof(uintptr_t));
    memcpy(bytes + sizeof(uintptr_t), values, sizeof(float) * HITBOX_COUNT);
    
    [data writeToFile:path atomically:YES];
}

bool loadCache(uintptr_t* outAddr, float* outValues) {
    NSString* path = getCachePath();
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < sizeof(uintptr_t) + sizeof(float) * HITBOX_COUNT)
        return false;
    
    const uint8_t* bytes = (const uint8_t*)data.bytes;
    memcpy(outAddr, bytes, sizeof(uintptr_t));
    memcpy(outValues, bytes + sizeof(uintptr_t), sizeof(float) * HITBOX_COUNT);
    
    // Верифицируем что адрес всё ещё валиден
    if (*outAddr != 0) {
        float checkVal = *(float*)*outAddr;
        if (fabsf(checkVal - stockValues[0]) > 0.01f) {
            *outAddr = 0; // Адрес невалиден, нужно пересканировать
            return false;
        }
    }
    
    return true;
}

// ==================== МЕНЮ (УПРОЩЁННЫЙ ВАРИАНТ БЕЗ IMGUI) ====================
// Поскольку ImGui требует сложной интеграции с Metal/OpenGL,
// используем UIAlertController с ActionSheet как замену

@interface HitboxMenuHandler : NSObject
+ (void)showMenu;
@end

@implementation HitboxMenuHandler

+ (void)showMenu {
    UIViewController* root = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow* w in scene.windows) {
                    if (w.rootViewController) { root = w.rootViewController; break; }
                }
            }
        }
    }
    if (!root) root = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (!root) return;
    
    UIAlertController* menu = [UIAlertController 
        alertControllerWithTitle:@"🎯 BlackRussia Hitbox"
        message:[NSString stringWithFormat:@"Адрес: 0x%lx\nГлобальный множитель: x%.1f",
                 g_headAddress, g_currentValues[0] / stockValues[0]]
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Быстрые множители
    float multipliers[] = {1.5f, 2.0f, 3.0f, 4.0f, 6.0f, 10.0f};
    for (int i = 0; i < 6; i++) {
        float mult = multipliers[i];
        NSString* title = [NSString stringWithFormat:@"x%.1f %@", mult, 
                          mult <= 2.0 ? @"🟢" : (mult <= 4.0 ? @"🟡" : @"🔴")];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction* _) {
            std::lock_guard<std::mutex> lock(g_mutex);
            float newValues[HITBOX_COUNT];
            for (int j = 0; j < HITBOX_COUNT; j++) {
                newValues[j] = stockValues[j] * mult;
            }
            safeWriteAllHitboxes(newValues);
            saveCache(g_headAddress, newValues);
        }]];
    }
    
    // Сброс
    [menu addAction:[UIAlertAction actionWithTitle:@"🔄 Сброс к стоку" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _) {
        std::lock_guard<std::mutex> lock(g_mutex);
        safeWriteAllHitboxes(stockValues);
        saveCache(g_headAddress, stockValues);
    }]];
    
    // Ручной ввод адреса
    [menu addAction:[UIAlertAction actionWithTitle:@"📝 Ввести адрес вручную" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _) {
        UIAlertController* input = [UIAlertController 
            alertControllerWithTitle:@"Введите адрес HEAD"
            message:@"В hex формате (например: 0x014EC888)"
            preferredStyle:UIAlertControllerStyleAlert];
        
        [input addTextFieldWithConfigurationHandler:^(UITextField* tf) {
            tf.placeholder = @"0x014EC888";
            tf.keyboardType = UIKeyboardTypeASCIICapable;
        }];
        
        [input addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _) {
            NSString* text = input.textFields[0].text;
            uintptr_t addr = strtoull([text UTF8String], NULL, 16);
            if (addr > 0) {
                g_headAddress = addr;
                saveCache(addr, g_currentValues);
            }
        }]];
        
        [input addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
        [root presentViewController:input animated:YES completion:nil];
    }]];
    
    // Сохранить
    [menu addAction:[UIAlertAction actionWithTitle:@"💾 Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _) {
        saveCache(g_headAddress, g_currentValues);
    }]];
    
    // Загрузить
    [menu addAction:[UIAlertAction actionWithTitle:@"📂 Загрузить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _) {
        uintptr_t addr;
        float vals[HITBOX_COUNT];
        if (loadCache(&addr, vals)) {
            g_headAddress = addr;
            safeWriteAllHitboxes(vals);
        }
    }]];
    
    // Закрыть
    [menu addAction:[UIAlertAction actionWithTitle:@"❌ Закрыть" style:UIAlertActionStyleCancel handler:nil]];
    
    [root presentViewController:menu animated:YES completion:nil];
}

@end

// ==================== ОБРАБОТЧИК КНОПОК ГРОМКОСТИ ====================
// Используем NSNotificationCenter для отслеживания нажатий
static int volumePressCount = 0;
static NSTimer* volumeTimer = nil;

void setupVolumeHandler() {
    // Подписываемся на изменение громкости
    [[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification* note) {
        volumePressCount++;
        
        if (volumeTimer) [volumeTimer invalidate];
        volumeTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer* _) {
            if (volumePressCount >= 3) {
                g_menuVisible = !g_menuVisible;
                if (g_menuVisible) {
                    [HitboxMenuHandler showMenu];
                }
            }
            volumePressCount = 0;
        }];
    }];
}

// ==================== ИНИЦИАЛИЗАЦИЯ ====================
__attribute__((constructor))
static void initialize() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        std::lock_guard<std::mutex> lock(g_mutex);
        
        // Пробуем загрузить из кэша
        if (!loadCache(&g_headAddress, g_currentValues)) {
            // Ищем адрес
            g_headAddress = findHitboxAddress();
            if (g_headAddress != 0) {
                memcpy(g_currentValues, stockValues, sizeof(stockValues));
                saveCache(g_headAddress, g_currentValues);
            }
        }
        
        if (g_headAddress != 0) {
            // Применяем сохранённые значения
            safeWriteAllHitboxes(g_currentValues);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                setupVolumeHandler();
            });
        }
        
        g_initialized = true;
        
        NSLog(@"[BRHitbox] Инициализация завершена. Адрес: 0x%lx", g_headAddress);
    });
}

// ==================== ПУБЛИЧНЫЕ ФУНКЦИИ ДЛЯ ЧАТ-КОМАНД ====================
extern "C" {
    // Вызывается когда игрок пишет /hbmenu в чат
    void showHitboxMenu() {
        dispatch_async(dispatch_get_main_queue(), ^{
            [HitboxMenuHandler showMenu];
        });
    }
    
    // Установить глобальный множитель
    void setHitboxMultiplier(float multiplier) {
        std::lock_guard<std::mutex> lock(g_mutex);
        float newValues[HITBOX_COUNT];
        for (int i = 0; i < HITBOX_COUNT; i++) {
            newValues[i] = stockValues[i] * multiplier;
        }
        safeWriteAllHitboxes(newValues);
        saveCache(g_headAddress, newValues);
    }
    
    // Получить текущий адрес
    uintptr_t getHitboxAddress() {
        return g_headAddress;
    }
}
