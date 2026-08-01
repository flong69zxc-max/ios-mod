// main.m - BlackRussia Hitbox x2 (ПРАВИЛЬНЫЙ патч с шагом 0x20)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <string.h>
#import <stdint.h>

// Структура: [значение которое ищем][проверочное значение через 0x20]
static struct {
    float original;
    float patched;
    float nextOriginal; // для верификации (каждое следующее)
} hitboxData[] = {
    {0.15f, 0.30f, 0.20f}, // HEAD -> next TORSO_1
    {0.20f, 0.40f, 0.25f}, // TORSO_1 -> next TORSO_2
    {0.25f, 0.50f, 0.25f}, // TORSO_2 -> next MID
    {0.25f, 0.50f, 0.16f}, // MID -> next LEFTARM
    {0.16f, 0.32f, 0.16f}, // LEFTARM -> next RIGHTARM
    {0.16f, 0.32f, 0.20f}, // RIGHTARM -> next LEFTLEG_1
    {0.20f, 0.40f, 0.20f}, // LEFTLEG_1 -> next RIGHTLEG_1
    {0.20f, 0.40f, 0.15f}, // RIGHTLEG_1 -> next LEFTLEG_2
    {0.15f, 0.30f, 0.15f}, // LEFTLEG_2 -> next RIGHTLEG_2
    {0.15f, 0.30f, 0.00f}  // RIGHTLEG_2 -> END
};

#define HITBOX_COUNT 10
#define HITBOX_STEP 0x20

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
        usleep(500000); // 0.5 сек
    }
}

void findAndPatch(void) {
    // Ищем blackrussia-client
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header *targetHeader = NULL;
    intptr_t targetSlide = 0;
    const char *targetPath = NULL;
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "blackrussia-client")) {
            targetHeader = _dyld_get_image_header(i);
            targetSlide = _dyld_get_image_vmaddr_slide(i);
            targetPath = name;
            break;
        }
    }
    
    if (!targetHeader) {
        showAlertNow(@"❌ Ошибка", @"blackrussia-client не найден");
        return;
    }
    
    // Границы библиотеки
    uintptr_t libStart = 0, libEnd = 0;
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
    
    int found = 0;
    uintptr_t foundAddr = 0;
    
    // Ищем ПЕРВОЕ значение 0.15, за которым через 0x20 идёт 0.20
    for (uintptr_t addr = libStart; addr < libEnd - (HITBOX_COUNT * HITBOX_STEP); addr += 4) {
        float *ptr = (float *)addr;
        float v0 = *ptr;
        
        // Проверяем первое значение
        if (fabsf(v0 - hitboxData[0].original) > 0.001f) continue;
        
        // Проверяем что следующее через 0x20 совпадает
        float *next = (float *)(addr + HITBOX_STEP);
        float v1 = *next;
        if (fabsf(v1 - hitboxData[0].nextOriginal) > 0.001f) continue;
        
        // Проверяем ВСЕ 10 значений с шагом 0x20
        BOOL allMatch = YES;
        for (int i = 1; i < HITBOX_COUNT; i++) {
            float *checkPtr = (float *)(addr + (i * HITBOX_STEP));
            float checkVal = *checkPtr;
            if (fabsf(checkVal - hitboxData[i].original) > 0.001f) {
                allMatch = NO;
                break;
            }
        }
        
        if (allMatch) {
            found = 1;
            foundAddr = addr;
            break;
        }
    }
    
    if (!found) {
        showAlertNow(@"❌ Не найдено", @"Структура хитбоксов не найдена.\nИгра обновилась?");
        return;
    }
    
    // ПАТЧИМ все 10 значений
    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)foundAddr,
                                  HITBOX_COUNT * HITBOX_STEP,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE);
    
    if (kr != KERN_SUCCESS) {
        showAlertNow(@"❌ Ошибка памяти", [NSString stringWithFormat:@"vm_protect: %d", kr]);
        return;
    }
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        float *patchPtr = (float *)(foundAddr + (i * HITBOX_STEP));
        *patchPtr = hitboxData[i].patched;
    }
    
    vm_protect(mach_task_self(),
              (vm_address_t)foundAddr,
              HITBOX_COUNT * HITBOX_STEP,
              FALSE,
              VM_PROT_READ);
    
    showAlertNow(@"✅ BlackRussia Hack",
                 [NSString stringWithFormat:
                  @"Хитбоксы x2!\n\n"
                  @"HEAD:      0.15 → 0.30\n"
                  @"TORSO_1:   0.20 → 0.40\n"
                  @"TORSO_2:   0.25 → 0.50\n"
                  @"MID:       0.25 → 0.50\n"
                  @"LEFTARM:   0.16 → 0.32\n"
                  @"RIGHTARM:  0.16 → 0.32\n"
                  @"LEFTLEG_1: 0.20 → 0.40\n"
                  @"RIGHTLEG_1:0.20 → 0.40\n"
                  @"LEFTLEG_2: 0.15 → 0.30\n"
                  @"RIGHTLEG_2:0.15 → 0.30\n\n"
                  @"Адрес: 0x%lx"]);
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC),
                   dispatch_get_global_queue(0, 0), ^{
        findAndPatch();
    });
}
