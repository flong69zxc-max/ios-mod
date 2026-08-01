#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <sys/mman.h>
#import <dlfcn.h>
#import <stdarg.h>

// ============ KittyMemory PORT ============
#ifdef __cplusplus
extern "C" {
#endif

#include <mach/mach.h>
#include <mach/vm_map.h>

// KittyMemory Core Functions
static uintptr_t get_base_address(const char *lib_name) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, lib_name)) {
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static uintptr_t find_pattern(const char *lib_name, const char *pattern, const char *mask) {
    uintptr_t base = get_base_address(lib_name);
    if (!base) return 0;
    
    // Получаем размер библиотеки
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, lib_name)) {
            struct mach_header_64 *header = (struct mach_header_64*)_dyld_get_image_header(i);
            if (!header) return 0;
            
            uintptr_t size = 0;
            struct load_command *cmd = (struct load_command*)((uintptr_t)header + sizeof(struct mach_header_64));
            for (uint32_t j = 0; j < header->ncmds; j++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    struct segment_command_64 *seg = (struct segment_command_64*)cmd;
                    if (strcmp(seg->segname, "__TEXT") == 0 || strcmp(seg->segname, "__DATA") == 0) {
                        size += seg->vmsize;
                    }
                }
                cmd = (struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
            }
            
            // Поиск паттерна
            size_t pattern_len = strlen(pattern);
            unsigned char *bytes = (unsigned char*)base;
            
            for (uintptr_t i = 0; i < size - pattern_len; i++) {
                BOOL found = YES;
                for (size_t j = 0; j < pattern_len; j++) {
                    if (mask[j] == 'x' && bytes[i + j] != pattern[j]) {
                        found = NO;
                        break;
                    }
                }
                if (found) {
                    return base + i;
                }
            }
        }
    }
    return 0;
}

static BOOL kitty_write_memory(uintptr_t addr, const void *data, size_t size) {
    if (!addr || !data || size == 0) return NO;
    
    // Изменяем права памяти
    vm_address_t page_start = (vm_address_t)addr & ~(vm_page_size - 1);
    vm_size_t page_size = vm_page_size;
    
    kern_return_t kr = vm_protect(mach_task_self(), page_start, page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    
    // Запись
    memcpy((void*)addr, data, size);
    
    // Очистка кэша
    __builtin___clear_cache((char*)addr, (char*)addr + size);
    
    // Восстанавливаем права
    vm_protect(mach_task_self(), page_start, page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    
    return YES;
}

#ifdef __cplusplus
}
#endif
// ============ END KittyMemory ============

#pragma mark - Конфигурация
#define PATCH_DELAY 3.0
#define MAX_RETRIES 3
#define RETRY_DELAY 1.0
#define LOG_FILE @"hitbox_patch.log"

typedef struct {
    float head;
    float pad1[7];
    float torso_1;
    float pad2[7];
    float torso_2;
    float pad3[7];
    float legs_1;
    float pad4[7];
    float legs_2;
    float pad5[7];
    float arms_1;
    float pad6[7];
    float arms_2;
    float pad7[7];
    float chest;
    float pad8[7];
    float stomach;
    float pad9[7];
    float pelvis;
} HitboxValues;

#pragma mark - Данные
static const float ORIGINAL[10] = {0.15f, 0.20f, 0.25f, 0.25f, 0.16f, 0.16f, 0.20f, 0.20f, 0.15f, 0.15f};
static const float NEW_VALUES[10] = {0.225f, 0.30f, 0.375f, 0.375f, 0.24f, 0.24f, 0.30f, 0.30f, 0.225f, 0.225f};
static const char *NAMES[10] = {"HEAD", "TORSO_1", "TORSO_2", "LEGS_1", "LEGS_2", "ARMS_1", "ARMS_2", "CHEST", "STOMACH", "PELVIS"};

// Паттерн для поиска (IDA-style с маской)
static const char *PATTERN = "\x9A\x99\x19\x3E";
static const char *MASK = "xxxx";

#pragma mark - Логгер
static void log_to_file(const char *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        char buffer[4096];
        vsnprintf(buffer, sizeof(buffer), format, args);
        va_end(args);
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = [paths firstObject];
        NSString *logPath = [doc stringByAppendingPathComponent:LOG_FILE];
        
        FILE *f = fopen([logPath UTF8String], "a");
        if (!f) return;
        
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        char ts[20];
        strftime(ts, sizeof(ts), "%H:%M:%S", tm);
        fprintf(f, "[%s] %s\n", ts, buffer);
        fclose(f);
    }
}

#pragma mark - UI
static void show_alert(const char *title, const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            UIAlertController *alert = [UIAlertController 
                alertControllerWithTitle:[NSString stringWithUTF8String:title]
                message:[NSString stringWithUTF8String:msg]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            
            UIViewController *root = nil;
            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        for (UIWindow *w in scene.windows) {
                            if (w.isKeyWindow && w.rootViewController) {
                                root = w.rootViewController;
                                break;
                            }
                        }
                    }
                }
            }
            if (!root) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                root = [UIApplication sharedApplication].keyWindow.rootViewController;
                #pragma clang diagnostic pop
            }
            if (root) {
                [root presentViewController:alert animated:YES completion:nil];
            }
        }
    });
}

#pragma mark - Поиск через KittyMemory
static void* find_hitbox_kitty(long *offset) {
    @autoreleasepool {
        log_to_file("🔍 Поиск хитбоксов через KittyMemory...");
        
        // Пробуем разные названия библиотек
        const char *libs[] = {"blackrussia-client", "BrBase", "BlackRussia", "client"};
        for (int i = 0; i < 4; i++) {
            uintptr_t addr = find_pattern(libs[i], PATTERN, MASK);
            if (addr) {
                log_to_file("✅ Найдено в %s по адресу %p", libs[i], (void*)addr);
                
                // Валидация
                HitboxValues *hb = (HitboxValues*)addr;
                float vals[10] = {
                    hb->head, hb->torso_1, hb->torso_2,
                    hb->legs_1, hb->legs_2, hb->arms_1,
                    hb->arms_2, hb->chest, hb->stomach, hb->pelvis
                };
                
                int match = 0;
                for (int j = 0; j < 10; j++) {
                    if (fabs(vals[j] - ORIGINAL[j]) < 0.001f) match++;
                }
                
                if (match >= 8) { // 8/10 совпадений достаточно
                    log_to_file("✅ Валидация пройдена (%d/10)", match);
                    *offset = addr - (uintptr_t)get_base_address(libs[i]);
                    return (void*)addr;
                } else {
                    log_to_file("⚠️ Валидация не пройдена (%d/10)", match);
                }
            }
        }
        
        log_to_file("❌ Хитбоксы не найдены");
        return NULL;
    }
}

#pragma mark - Основной патч
static BOOL apply_patch() {
    @autoreleasepool {
        log_to_file("=== НАЧАЛО ПАТЧА ===");
        
        long offset = 0;
        void *addr = find_hitbox_kitty(&offset);
        
        if (!addr) {
            log_to_file("❌ Патч невозможен - хитбоксы не найдены");
            return NO;
        }
        
        log_to_file("📍 Адрес: %p (смещение: 0x%lX)", addr, offset);
        
        HitboxValues *hb = (HitboxValues*)addr;
        
        // Бэкап
        HitboxValues backup;
        memcpy(&backup, hb, sizeof(HitboxValues));
        
        // Старые значения
        float old[10];
        old[0] = hb->head;
        old[1] = hb->torso_1;
        old[2] = hb->torso_2;
        old[3] = hb->legs_1;
        old[4] = hb->legs_2;
        old[5] = hb->arms_1;
        old[6] = hb->arms_2;
        old[7] = hb->chest;
        old[8] = hb->stomach;
        old[9] = hb->pelvis;
        
        log_to_file("📊 СТАРЫЕ ЗНАЧЕНИЯ:");
        for (int i = 0; i < 10; i++) {
            log_to_file("  %s: %.3f", NAMES[i], old[i]);
        }
        
        // Подготовка новых значений
        HitboxValues new_hb = *hb;
        new_hb.head = NEW_VALUES[0];
        new_hb.torso_1 = NEW_VALUES[1];
        new_hb.torso_2 = NEW_VALUES[2];
        new_hb.legs_1 = NEW_VALUES[3];
        new_hb.legs_2 = NEW_VALUES[4];
        new_hb.arms_1 = NEW_VALUES[5];
        new_hb.arms_2 = NEW_VALUES[6];
        new_hb.chest = NEW_VALUES[7];
        new_hb.stomach = NEW_VALUES[8];
        new_hb.pelvis = NEW_VALUES[9];
        
        // Запись через KittyMemory
        if (!kitty_write_memory((uintptr_t)addr, &new_hb, sizeof(HitboxValues))) {
            log_to_file("❌ Ошибка записи в память");
            memcpy(hb, &backup, sizeof(HitboxValues));
            return NO;
        }
        
        // Верификация
        float verify[10];
        verify[0] = hb->head;
        verify[1] = hb->torso_1;
        verify[2] = hb->torso_2;
        verify[3] = hb->legs_1;
        verify[4] = hb->legs_2;
        verify[5] = hb->arms_1;
        verify[6] = hb->arms_2;
        verify[7] = hb->chest;
        verify[8] = hb->stomach;
        verify[9] = hb->pelvis;
        
        BOOL success = YES;
        for (int i = 0; i < 10; i++) {
            if (fabs(verify[i] - NEW_VALUES[i]) > 0.001f) {
                success = NO;
                log_to_file("❌ Верификация не пройдена для %s", NAMES[i]);
                break;
            }
        }
        
        if (!success) {
            log_to_file("❌ Патч провалился - восстанавливаем бэкап");
            memcpy(hb, &backup, sizeof(HitboxValues));
            return NO;
        }
        
        log_to_file("📊 НОВЫЕ ЗНАЧЕНИЯ (ПРОВЕРЕНО):");
        for (int i = 0; i < 10; i++) {
            log_to_file("  %s: %.3f ✅", NAMES[i], NEW_VALUES[i]);
        }
        
        // UI сообщение
        char msg[2048];
        snprintf(msg, sizeof(msg),
                 "✅ ПАТЧ ПРИМЕНЁН УСПЕШНО\n"
                 "─────────────────────────────\n"
                 "📍 Адрес: %p\n"
                 "📌 Смещение: 0x%lX\n"
                 "─────────────────────────────\n\n"
                 "📊 ИЗМЕНЕНИЯ:\n"
                 "HEAD:     %.3f → %.3f\n"
                 "TORSO_1:  %.3f → %.3f\n"
                 "TORSO_2:  %.3f → %.3f\n"
                 "LEGS_1:   %.3f → %.3f\n"
                 "LEGS_2:   %.3f → %.3f\n"
                 "ARMS_1:   %.3f → %.3f\n"
                 "ARMS_2:   %.3f → %.3f\n"
                 "CHEST:    %.3f → %.3f\n"
                 "STOMACH:  %.3f → %.3f\n"
                 "PELVIS:   %.3f → %.3f\n"
                 "─────────────────────────────\n"
                 "✅ Все изменения верифицированы!",
                 addr, offset,
                 old[0], NEW_VALUES[0],
                 old[1], NEW_VALUES[1],
                 old[2], NEW_VALUES[2],
                 old[3], NEW_VALUES[3],
                 old[4], NEW_VALUES[4],
                 old[5], NEW_VALUES[5],
                 old[6], NEW_VALUES[6],
                 old[7], NEW_VALUES[7],
                 old[8], NEW_VALUES[8],
                 old[9], NEW_VALUES[9]);
        
        log_to_file("✅ ПАТЧ УСПЕШНО ПРИМЕНЁН");
        show_alert("🎯 ПАТЧ ХИТБОКСОВ", msg);
        
        return YES;
    }
}

#pragma mark - Инициализация
__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool {
            log_to_file("=== KittyMemory INIT ===");
            [NSThread sleepForTimeInterval:PATCH_DELAY];
            
            int retries = 0;
            BOOL success = NO;
            
            while (retries < MAX_RETRIES && !success) {
                log_to_file("🔄 Попытка #%d", retries + 1);
                success = apply_patch();
                
                if (!success) {
                    retries++;
                    if (retries < MAX_RETRIES) {
                        log_to_file("⏳ Повтор через %.1fс", RETRY_DELAY);
                        [NSThread sleepForTimeInterval:RETRY_DELAY];
                    }
                }
            }
            
            if (!success) {
                log_to_file("❌ ВСЕ ПОПЫТКИ ПРОВАЛИЛИСЬ (%d)", MAX_RETRIES);
                show_alert("❌ ОШИБКА", 
                          "Не удалось применить патч.\n"
                          "Лог: Documents/hitbox_patch.log");
            }
        }
    });
}

#pragma mark - Main
int main() {
    @autoreleasepool {
        init();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
