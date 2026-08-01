// main.m - BlackRussia Hitbox x2 (АВТОПОИСК ОФФСЕТА)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <string.h>
#import <stdint.h>
#import <math.h>

// Значения для патча
static struct {
    float original;
    float patched;
} hitboxData[] = {
    {0.15f, 0.30f}, // HEAD
    {0.20f, 0.40f}, // TORSO_1
    {0.25f, 0.50f}, // TORSO_2
    {0.25f, 0.50f}, // MID
    {0.16f, 0.32f}, // LEFTARM
    {0.16f, 0.32f}, // RIGHTARM
    {0.20f, 0.40f}, // LEFTLEG_1
    {0.20f, 0.40f}, // RIGHTLEG_1
    {0.15f, 0.30f}, // LEFTLEG_2
    {0.15f, 0.30f}  // RIGHTLEG_2
};

#define HITBOX_COUNT 10
#define HITBOX_STEP 0x20

// Показывает алерт
void showAlertNow(NSString *title, NSString *msg) {
    for (int attempt = 0; attempt < 20; attempt++) {
        __block BOOL shown = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIViewController *root = nil;
            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        for (UIWindow *w in scene.windows) {
                            if (w.rootViewController) { root = w.rootViewController; break; }
                        }
                    }
                }
            }
            if (!root) root = [UIApplication sharedApplication].keyWindow.rootViewController;
            
            if (root && root.view.window) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [root presentViewController:alert animated:YES completion:nil];
                shown = YES;
            }
        });
        if (shown) return;
        usleep(500000);
    }
}

// Поиск первого хитбокса (0.15 за которым через 0x20 идёт 0.20)
uintptr_t findHeadOffset(const struct mach_header *header, intptr_t slide) {
    // Получаем границы памяти библиотеки
    uintptr_t libStart = 0;
    uintptr_t libEnd = 0;
    
    struct mach_header_64 *header64 = (struct mach_header_64 *)header;
    struct load_command *lc = (struct load_command *)((char *)header64 + sizeof(struct mach_header_64));
    
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            uintptr_t segStart = seg->vmaddr + slide;
            uintptr_t segEnd = segStart + seg->vmsize;
            if (libStart == 0 || segStart < libStart) libStart = segStart;
            if (segEnd > libEnd) libEnd = segEnd;
        }
        lc = (struct load_command *)((char *)lc + lc->cmdsize);
    }
    
    // Сканируем каждый 4-й байт (выравнивание float)
    for (uintptr_t addr = libStart; addr < libEnd - (HITBOX_COUNT * HITBOX_STEP); addr += 4) {
        float v0 = *(float *)addr;
        
        // Проверяем первое значение — 0.15
        if (fabsf(v0 - 0.15f) > 0.001f) continue;
        
        // Проверяем второе значение через 0x20 — должно быть 0.20
        float v1 = *(float *)(addr + HITBOX_STEP);
        if (fabsf(v1 - 0.20f) > 0.001f) continue;
        
        // Проверяем третье значение ещё через 0x20 — должно быть 0.25
        float v2 = *(float *)(addr + (2 * HITBOX_STEP));
        if (fabsf(v2 - 0.25f) > 0.001f) continue;
        
        // Нашли! Возвращаем оффсет от начала библиотеки
        return addr - (uintptr_t)header;
    }
    
    return 0; // Не найдено
}

// Основная логика
void doPatch(void) {
    // Ищем библиотеку
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header *targetHeader = NULL;
    intptr_t targetSlide = 0;
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "blackrussia-client")) {
            targetHeader = _dyld_get_image_header(i);
            targetSlide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    
    if (!targetHeader) {
        showAlertNow(@"❌ Ошибка", @"Библиотека не найдена!");
        return;
    }
    
    // Ищем оффсет
    uintptr_t headOffset = findHeadOffset(targetHeader, targetSlide);
    
    if (headOffset == 0) {
        showAlertNow(@"❌ Не найдено", @"Хитбоксы не найдены в памяти!");
        return;
    }
    
    // Вычисляем реальный адрес
    uintptr_t headAddr = (uintptr_t)targetHeader + headOffset;
    
    // Патчим
    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)headAddr,
                                  HITBOX_COUNT * HITBOX_STEP,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE);
    
    if (kr != KERN_SUCCESS) {
        showAlertNow(@"❌ Ошибка", [NSString stringWithFormat:@"vm_protect: %d\nAddr: 0x%lx", kr, headAddr]);
        return;
    }
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        float *ptr = (float *)(headAddr + (i * HITBOX_STEP));
        *ptr = hitboxData[i].patched;
    }
    
    vm_protect(mach_task_self(),
              (vm_address_t)headAddr,
              HITBOX_COUNT * HITBOX_STEP,
              FALSE,
              VM_PROT_READ);
    
    // Показываем результат с адресом
    showAlertNow(@"✅ Успешно!",
                 [NSString stringWithFormat:
                  @"🎯 Адрес HEAD: 0x%lx\n"
                  @"📌 Оффсет: 0x%lx\n\n"
                  @"HEAD:       0.15 → 0.30\n"
                  @"TORSO_1:    0.20 → 0.40\n"
                  @"TORSO_2:    0.25 → 0.50\n"
                  @"MID:        0.25 → 0.50\n"
                  @"LEFTARM:    0.16 → 0.32\n"
                  @"RIGHTARM:   0.16 → 0.32\n"
                  @"LEFTLEG_1:  0.20 → 0.40\n"
                  @"RIGHTLEG_1: 0.20 → 0.40\n"
                  @"LEFTLEG_2:  0.15 → 0.30\n"
                  @"RIGHTLEG_2: 0.15 → 0.30",
                  headAddr, headOffset]);
}

// Точка входа
__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC),
                   dispatch_get_global_queue(0, 0), ^{
        doPatch();
    });
}
