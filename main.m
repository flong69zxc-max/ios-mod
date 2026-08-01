// main.m - Инжект для Black Russia (меняем значения лута x2)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <string.h>

// Значения для поиска
static float searchValues[] = {0.15, 0.20, 0.25, 0.25, 0.16, 0.16, 0.20, 0.20, 0.15, 0.15};
static int searchCount = 10;
static int foundCount = 0;
static int patchedCount = 0;

// Показываем уведомление
void showNotification(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Ждём немного, чтобы UI был готов
        sleep(1);
        
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:title 
            message:message 
            preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *okAction = [UIAlertAction 
            actionWithTitle:@"OK" 
            style:UIAlertActionStyleDefault 
            handler:nil];
        
        [alert addAction:okAction];
        
        UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

// Поиск и патч значений в памяти
void patchBlackRussia(void) {
    // Получаем образ blackrussia-client в памяти
    uint32_t count = _dyld_image_count();
    const struct mach_header *targetHeader = NULL;
    intptr_t targetSlide = 0;
    const char *targetName = NULL;
    
    // Ищем blackrussia-client
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "blackrussia-client")) {
            targetHeader = _dyld_get_image_header(i);
            targetSlide = _dyld_get_image_vmaddr_slide(i);
            targetName = name;
            break;
        }
    }
    
    if (!targetHeader) {
        showNotification(@"Ошибка", @"BlackRussia не найдена в памяти!");
        return;
    }
    
    // Получаем сегмент __TEXT (где лежат константы)
    struct segment_command_64 *textSeg = NULL;
    struct section_64 *constSec = NULL;
    
    struct mach_header_64 *header64 = (struct mach_header_64 *)targetHeader;
    struct load_command *lc = (struct load_command *)((char *)header64 + sizeof(struct mach_header_64));
    
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            
            if (strcmp(seg->segname, "__TEXT") == 0) {
                textSeg = seg;
                
                // Ищем __const секцию
                struct section_64 *sect = (struct section_64 *)((char *)seg + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sect[j].sectname, "__const") == 0) {
                        constSec = &sect[j];
                        break;
                    }
                }
                break;
            }
        }
        lc = (struct load_command *)((char *)lc + lc->cmdsize);
    }
    
    if (!constSec) {
        // Пробуем __cstring если __const не нашли
        struct mach_header_64 *header64_2 = (struct mach_header_64 *)targetHeader;
        struct load_command *lc2 = (struct load_command *)((char *)header64_2 + sizeof(struct mach_header_64));
        
        for (uint32_t i = 0; i < header64_2->ncmds; i++) {
            if (lc2->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)lc2;
                struct section_64 *sect = (struct section_64 *)((char *)seg + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sect[j].sectname, "__cstring") == 0) {
                        constSec = &sect[j];
                        break;
                    }
                }
                if (constSec) break;
            }
            lc2 = (struct load_command *)((char *)lc2 + lc2->cmdsize);
        }
    }
    
    // Ищем по всей памяти, куда замаплена библиотека
    // Получаем её размер через все сегменты
    struct mach_header_64 *headerScan = (struct mach_header_64 *)targetHeader;
    struct load_command *lcScan = (struct load_command *)((char *)headerScan + sizeof(struct mach_header_64));
    
    uintptr_t startAddr = 0;
    uintptr_t endAddr = 0;
    
    for (uint32_t i = 0; i < headerScan->ncmds; i++) {
        if (lcScan->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lcScan;
            if (seg->vmaddr > 0) {
                uintptr_t segStart = seg->vmaddr + targetSlide;
                uintptr_t segEnd = segStart + seg->vmsize;
                
                if (startAddr == 0 || segStart < startAddr) startAddr = segStart;
                if (segEnd > endAddr) endAddr = segEnd;
            }
        }
        lcScan = (struct load_command *)((char *)lcScan + lcScan->cmdsize);
    }
    
    foundCount = 0;
    patchedCount = 0;
    
    // Второй проход: ищем float значения с шагом 0x20
    for (int searchIdx = 0; searchIdx < searchCount; searchIdx++) {
        float targetValue = searchValues[searchIdx];
        float newValue = targetValue * 2.0;
        
        // Сканим всю память библиотеки с шагом 0x20
        for (uintptr_t addr = startAddr; addr < endAddr - sizeof(float); addr += 0x20) {
            float *ptr = (float *)addr;
            
            // Проверяем, что адрес выровнен и значение совпадает
            if ((addr & 3) == 0) {  // выравнивание по 4 байта для float
                float val = *ptr;
                if (fabsf(val - targetValue) < 0.001) {
                    foundCount++;
                    
                    // Меняем защиту памяти на запись
                    vm_prot_t curProt, maxProt;
                    vm_address_t regionAddr = (vm_address_t)ptr;
                    vm_size_t regionSize = sizeof(float);
                    
                    kern_return_t kr = vm_remap(mach_task_self(), 
                                                 &regionAddr, 
                                                 regionSize, 
                                                 0, 
                                                 VM_FLAGS_ANYWHERE,
                                                 mach_task_self(),
                                                 (vm_address_t)ptr,
                                                 FALSE,
                                                 &curProt, 
                                                 &maxProt, 
                                                 VM_INHERIT_DEFAULT);
                    
                    if (kr != KERN_SUCCESS) {
                        // Пробуем через mprotect
                        vm_protect(mach_task_self(), (vm_address_t)ptr, sizeof(float), FALSE, VM_PROT_READ | VM_PROT_WRITE);
                    }
                    
                    // Патчим
                    *ptr = newValue;
                    
                    // Возвращаем защиту
                    vm_protect(mach_task_self(), (vm_address_t)ptr, sizeof(float), FALSE, VM_PROT_READ);
                    
                    patchedCount++;
                }
            }
        }
    }
    
    // Показываем результат
    dispatch_async(dispatch_get_main_queue(), ^{
        sleep(2);
        
        NSString *msg;
        if (patchedCount > 0) {
            msg = [NSString stringWithFormat:
                   @"✅ Успешный инжект!\n"
                   @"📦 Библиотека: blackrussia-client\n"
                   @"🔍 Найдено значений: %d\n"
                   @"🔧 Запатчено: %d (x2)\n\n"
                   @"0.15 → 0.30\n"
                   @"0.20 → 0.40\n"
                   @"0.25 → 0.50\n"
                   @"0.16 → 0.32\n\n"
                   @"💎 Весь лут x2!",
                   foundCount, patchedCount];
        } else {
            msg = @"❌ Не найдены значения для патча.\nВозможно, игра обновилась.";
        }
        
        showNotification(@"BlackRussia Hack", msg);
    });
}

// Constructor - выполняется при загрузке dylib
__attribute__((constructor))
static void initHack(void) {
    // Ждём загрузки всех библиотек
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3.0 * NSEC_PER_SEC), 
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        patchBlackRussia();
    });
}

// Пустой класс для линковки
@interface HackMain : NSObject
@end
@implementation HackMain
@end
