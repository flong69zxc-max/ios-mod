// main.m - BlackRussia Hitbox Multiplier x2 (фикс поиска фреймворка)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <string.h>
#import <stdint.h>

// Оригинальная последовательность байт (10 float'ов подряд)
static const uint8_t originalBytes[] = {
    0x9A, 0x99, 0x19, 0x3E,  // 0.15 - HEAD
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20 - TORSO_1
    0x00, 0x00, 0x80, 0x3E,  // 0.25 - TORSO_2
    0x00, 0x00, 0x80, 0x3E,  // 0.25 - MID
    0x48, 0xE1, 0x24, 0x3E,  // 0.16 - LEFTARM
    0x48, 0xE1, 0x24, 0x3E,  // 0.16 - RIGHTARM
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20 - LEFTLEG_1
    0xCD, 0xCC, 0x4C, 0x3E,  // 0.20 - RIGHTLEG_1
    0x9A, 0x99, 0x19, 0x3E,  // 0.15 - LEFTLEG_2
    0x9A, 0x99, 0x19, 0x3E   // 0.15 - RIGHTLEG_2
};

// Запатченная последовательность (x2)
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

void showAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sleep(2);
        
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:title 
            message:message 
            preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        
        // Ищем активное окно
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in scene.windows) {
                    if (window.rootViewController) {
                        [window.rootViewController presentViewController:alert animated:YES completion:nil];
                        return;
                    }
                }
            }
        }
        
        // Fallback
        UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

void findAndPatch(void) {
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header *targetHeader = NULL;
    intptr_t targetSlide = 0;
    const char *targetPath = NULL;
    
    NSLog(@"[BRHack] Сканируем %d загруженных образов...", imageCount);
    
    // Ищем blackrussia-client где угодно в пути
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        
        // Ищем "blackrussia-client" в любом месте пути
        if (strstr(name, "blackrussia-client")) {
            targetHeader = _dyld_get_image_header(i);
            targetSlide = _dyld_get_image_vmaddr_slide(i);
            targetPath = name;
            NSLog(@"[BRHack] ✅ Найден образ: %s (индекс %d)", name, i);
            break;
        }
    }
    
    if (!targetHeader) {
        // Вывод всех образов для диагностики
        NSLog(@"[BRHack] ❌ blackrussia-client не найден. Все образы:");
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *name = _dyld_get_image_name(i);
            if (strstr(name, "BrBase") || strstr(name, "blackrussia") || strstr(name, "Black")) {
                NSLog(@"[BRHack]   [%d] %s", i, name);
            }
        }
        showAlert(@"❌ Ошибка", @"Библиотека не найдена.\nПроверь консоль (логи).");
        return;
    }
    
    // Получаем границы памяти
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
            
            NSLog(@"[BRHack] Сегмент %s: 0x%lx - 0x%lx (размер: %llu)",
                  seg->segname, segStart, segEnd, seg->vmsize);
        }
        lc = (struct load_command *)((char *)lc + lc->cmdsize);
    }
    
    NSLog(@"[BRHack] Полный диапазон: 0x%lx - 0x%lx (%lu байт)",
          libStart, libEnd, libEnd - libStart);
    
    // Сканируем
    patchCount = 0;
    uintptr_t scanEnd = libEnd - PATTERN_SIZE;
    
    for (uintptr_t addr = libStart; addr < scanEnd; addr++) {
        if (memcmp((void *)addr, originalBytes, PATTERN_SIZE) == 0) {
            NSLog(@"[BRHack] 🎯 Найдено по адресу: 0x%lx", addr);
            
            kern_return_t kr = vm_protect(mach_task_self(),
                                          (vm_address_t)addr,
                                          PATTERN_SIZE,
                                          FALSE,
                                          VM_PROT_READ | VM_PROT_WRITE);
            
            if (kr == KERN_SUCCESS) {
                memcpy((void *)addr, patchedBytes, PATTERN_SIZE);
                
                vm_protect(mach_task_self(),
                          (vm_address_t)addr,
                          PATTERN_SIZE,
                          FALSE,
                          VM_PROT_READ);
                
                patchCount++;
                NSLog(@"[BRHack] ✅ Успешно запатчено!");
                break;
            } else {
                NSLog(@"[BRHack] ❌ vm_protect ошибка: %d (адрес 0x%lx)", kr, addr);
            }
        }
    }
    
    if (patchCount > 0) {
        showAlert(@"✅ BlackRussia Hack",
                  @"Урон по всем частям тела x2!\n\n"
                  "HEAD:     0.15 → 0.30\n"
                  "TORSO_1:  0.20 → 0.40\n"
                  "TORSO_2:  0.25 → 0.50\n"
                  "MID:      0.25 → 0.50\n"
                  "LEFTARM:  0.16 → 0.32\n"
                  "RIGHTARM: 0.16 → 0.32\n"
                  "LEFTLEG:  0.20 → 0.40\n"
                  "RIGHTLEG: 0.20 → 0.40\n"
                  "LEGS:     0.15 → 0.30");
    } else {
        showAlert(@"❌ Не найдено",
                  @"Паттерн не найден.\n\n"
                  @"Смотри логи в консоли:\n"
                  @"• Адреса сегментов\n"
                  @"• Возможно нужна другая задержка");
    }
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[BRHack] ========== ИНИЦИАЛИЗАЦИЯ ==========");
    NSLog(@"[BRHack] Dylib загружен, ждём 7 секунд...");
    
    // Увеличенная задержка для гарантии загрузки фреймворка
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7.0 * NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        findAndPatch();
    });
}
