// main.m - BlackRussia Hitbox Multiplier x2
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <string.h>
#import <stdint.h>

// Оригинальная последовательность байт (10 float'ов подряд)
// HEAD:      9A 99 19 3E = 0.15
// TORSO_1:   CD CC 4C 3E = 0.20
// TORSO_2:   00 00 80 3E = 0.25
// MID:       00 00 80 3E = 0.25
// LEFTARM:   48 E1 24 3E = 0.16
// RIGHTARM:  48 E1 24 3E = 0.16
// LEFTLEG_1: CD CC 4C 3E = 0.20
// RIGHTLEG_1:CD CC 4C 3E = 0.20
// LEFTLEG_2: 9A 99 19 3E = 0.15
// RIGHTLEG_2:9A 99 19 3E = 0.15
static const uint8_t originalBytes[] = {
    0x9A, 0x99, 0x19, 0x3E,  // 0.15
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20
    0x00, 0x00, 0x80, 0x3E,  // 0.25
    0x00, 0x00, 0x80, 0x3E,  // 0.25
    0x48, 0xE1, 0x24, 0x3E,  // 0.16
    0x48, 0xE1, 0x24, 0x3E,  // 0.16
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20
    0x9A, 0x99, 0x19, 0x3E,  // 0.15
    0x9A, 0x99, 0x19, 0x3E   // 0.15
};

// Запатченная последовательность (x2)
// 0.15->0.30, 0.20->0.40, 0.25->0.50, 0.16->0.32
static const uint8_t patchedBytes[] = {
    0x9A, 0x99, 0x99, 0x3E,  // 0.30
    0xCD, 0xCC, 0xCC, 0x3E,  // 0.40
    0x00, 0x00, 0x00, 0x3F,  // 0.50
    0x00, 0x00, 0x00, 0x3F,  // 0.50
    0x48, 0xE1, 0xA4, 0x3E,  // 0.32
    0x48, 0xE1, 0xA4, 0x3E,  // 0.32
    0xCD, 0xCC, 0xCC, 0x3E,  // 0.40
    0xCD, 0xCC, 0xCC, 0x3E,  // 0.40
    0x9A, 0x99, 0x99, 0x3E,  // 0.30
    0x9A, 0x99, 0x99, 0x3E   // 0.30
};

#define PATTERN_SIZE (sizeof(originalBytes))

static int patchCount = 0;

// Показать алерт
void showAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sleep(2); // Ждём прогрузки UI игры
        
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:title 
            message:message 
            preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        
        UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        } else {
            // Если нет rootViewController, пробуем найти любое окно
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                if (window.rootViewController) {
                    [window.rootViewController presentViewController:alert animated:YES completion:nil];
                    break;
                }
            }
        }
    });
}

// Поиск и патч последовательности байт
void findAndPatch(void) {
    // Ищем библиотеку blackrussia-client
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header *targetHeader = NULL;
    intptr_t targetSlide = 0;
    const char *targetPath = NULL;
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        // Ищем точное совпадение имени файла (без пути)
        const char *lastSlash = strrchr(name, '/');
        const char *fileName = lastSlash ? lastSlash + 1 : name;
        
        if (strcmp(fileName, "blackrussia-client") == 0) {
            targetHeader = _dyld_get_image_header(i);
            targetSlide = _dyld_get_image_vmaddr_slide(i);
            targetPath = name;
            break;
        }
    }
    
    if (!targetHeader) {
        showAlert(@"❌ Ошибка", @"Библиотека blackrussia-client не найдена!\nВозможно, изменилось название.");
        return;
    }
    
    // Получаем границы памяти библиотеки
    uintptr_t libStart = 0;
    uintptr_t libEnd = 0;
    
    struct mach_header_64 *header64 = (struct mach_header_64 *)targetHeader;
    struct load_command *lc = (struct load_command *)((char *)header64 + sizeof(struct mach_header_64));
    
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            uintptr_t segStart = seg->vmaddr + targetSlide;
            uintptr_t segEnd = segStart + seg->vmsize;
            
            if (libStart == 0 || segStart < libStart) libStart = segStart;
            if (segEnd > libEnd) libEnd = segEnd;
        }
        lc = (struct load_command *)((char *)lc + lc->cmdsize);
    }
    
    NSLog(@"[BlackRussia] Library: %s", targetPath);
    NSLog(@"[BlackRussia] Memory range: 0x%lx - 0x%lx", libStart, libEnd);
    
    // Сканируем память на точное совпадение последовательности
    patchCount = 0;
    uintptr_t scanStart = libStart;
    uintptr_t scanEnd = libEnd - PATTERN_SIZE;
    
    for (uintptr_t addr = scanStart; addr < scanEnd; addr++) {
        // Проверяем, совпадает ли последовательность
        if (memcmp((void *)addr, originalBytes, PATTERN_SIZE) == 0) {
            NSLog(@"[BlackRussia] Найдена последовательность по адресу: 0x%lx", addr);
            
            // Меняем защиту памяти на RW
            kern_return_t kr = vm_protect(mach_task_self(), 
                                          (vm_address_t)addr, 
                                          PATTERN_SIZE, 
                                          FALSE, 
                                          VM_PROT_READ | VM_PROT_WRITE);
            
            if (kr == KERN_SUCCESS) {
                // Копируем запатченные байты
                memcpy((void *)addr, patchedBytes, PATTERN_SIZE);
                
                // Возвращаем защиту (только чтение)
                vm_protect(mach_task_self(), 
                          (vm_address_t)addr, 
                          PATTERN_SIZE, 
                          FALSE, 
                          VM_PROT_READ);
                
                patchCount++;
                NSLog(@"[BlackRussia] ✅ Успешно запатчено! (патч #%d)", patchCount);
                
                // Выходим после первого найденного (обычно он один)
                break;
            } else {
                NSLog(@"[BlackRussia] ❌ Ошибка vm_protect: %d", kr);
            }
        }
    }
    
    // Показываем результат
    if (patchCount > 0) {
        showAlert(@"✅ BlackRussia Hack", 
                  [NSString stringWithFormat:
                   @"Успешный инжект!\n\n"
                   @"🔹 HEAD:     0.15 → 0.30\n"
                   @"🔹 TORSO_1:  0.20 → 0.40\n"
                   @"🔹 TORSO_2:  0.25 → 0.50\n"
                   @"🔹 MID:      0.25 → 0.50\n"
                   @"🔹 LEFTARM:  0.16 → 0.32\n"
                   @"🔹 RIGHTARM: 0.16 → 0.32\n"
                   @"🔹 LEFTLEG:  0.20 → 0.40\n"
                   @"🔹 RIGHTLEG: 0.20 → 0.40\n"
                   @"🔹 LEGS:     0.15 → 0.30\n\n"
                   @"🎯 Урон по всем частям тела x2!\n"
                   @"📍 Адрес: 0x%lx", (unsigned long)libStart]);
    } else {
        showAlert(@"❌ Не найдено", 
                  @"Последовательность не найдена в памяти.\n\n"
                  @"Возможные причины:\n"
                  @"• Игра обновилась\n"
                  @"• Библиотека зашифрована\n"
                  @"• Нужно дождаться загрузки в мир");
    }
}

// Constructor - запускается при инжекте
__attribute__((constructor))
static void init(void) {
    NSLog(@"[BlackRussia] Dylib загружен, ждём 5 секунд...");
    
    // Ждём 5 секунд чтобы игра точно загрузилась и распаковала библиотеку
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        findAndPatch();
    });
}
