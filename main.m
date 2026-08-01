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

#pragma mark - Конфигурация
#define PATCH_DELAY 3.0
#define MAX_RETRIES 5
#define RETRY_DELAY 1.0
#define LOG_FILE @"hitbox_patch.log"
#define MEMORY_PROTECT_PAGES 4096

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

// Множественные сигнатуры для разных версий
static const unsigned char SIGNATURES[][4] = {
    {0x9A, 0x99, 0x19, 0x3E},  // v1.0
    {0x9A, 0x99, 0x19, 0x3F},  // v1.1
    {0xCD, 0xCC, 0xCC, 0x3E}   // v2.0
};
static const int SIGNATURE_COUNT = sizeof(SIGNATURES) / sizeof(SIGNATURES[0]);

#pragma mark - Логгер с поддержкой форматирования
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
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);
        fprintf(f, "[%s] %s\n", ts, buffer);
        fclose(f);
    }
}

#pragma mark - UI Уведомления
static void show_alert(const char *title, const char *msg, BOOL is_error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            UIAlertController *alert = [UIAlertController 
                alertControllerWithTitle:[NSString stringWithUTF8String:title]
                message:[NSString stringWithUTF8String:msg]
                preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            
            UIViewController *root = nil;
            
            // iOS 13+ совместимый способ получения root VC
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
            
            // Fallback для старых iOS
            if (!root) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                root = [UIApplication sharedApplication].keyWindow.rootViewController;
                #pragma clang diagnostic pop
            }
            
            if (!root) {
                // Последний fallback - берем любой window с root VC
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    if (w.rootViewController) {
                        root = w.rootViewController;
                        break;
                    }
                }
            }
            
            if (root) {
                [root presentViewController:alert animated:YES completion:nil];
            }
        }
    });
}

#pragma mark - Безопасная запись в память
static BOOL safe_memory_write(void *addr, const void *data, size_t size) {
    if (!addr || !data || size == 0) return NO;
    
    // Выравнивание страницы
    uintptr_t page_start = (uintptr_t)addr & ~(MEMORY_PROTECT_PAGES - 1);
    size_t page_size = MEMORY_PROTECT_PAGES;
    
    // Сохраняем текущие права
    int prot = 0;
    if (mprotect((void *)page_start, page_size, PROT_READ | PROT_WRITE) != 0) {
        log_to_file("❌ Не удалось изменить права памяти");
        return NO;
    }
    
    // Запись данных
    memcpy(addr, data, size);
    
    // Сброс кэша инструкций (ARM)
    __builtin___clear_cache((char *)addr, (char *)addr + size);
    
    // Восстановление прав
    mprotect((void *)page_start, page_size, prot);
    
    return YES;
}

#pragma mark - Поиск хитбоксов с множественными сигнатурами
static void* find_hitbox(long *offset, int *sig_index) {
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        
        // Поддержка нескольких названий бинарников
        if (!strstr(name, "blackrussia-client") && 
            !strstr(name, "BrBase") && 
            !strstr(name, "BlackRussia")) continue;
        
        void *base = (void *)_dyld_get_image_vmaddr_slide(i);
        struct mach_header_64 *header = (struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header) continue;
        
        // Получаем размер сегментов
        uintptr_t text_size = 0, data_size = 0;
        struct load_command *cmd = (struct load_command *)((uintptr_t)header + sizeof(struct mach_header_64));
        
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__TEXT") == 0) text_size = seg->vmsize;
                if (strcmp(seg->segname, "__DATA") == 0) data_size = seg->vmsize;
            }
            cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
        }
        
        size_t total_size = text_size + data_size;
        if (total_size == 0) continue;
        
        unsigned char *start = (unsigned char *)base;
        
        // Поиск по всем сигнатурам
        for (int sig = 0; sig < SIGNATURE_COUNT; sig++) {
            const unsigned char *pattern = SIGNATURES[sig];
            
            for (uintptr_t pos = 0; pos < total_size - 4; pos += 4) {
                if (memcmp(start + pos, pattern, 4) == 0) {
                    HitboxValues *hb = (HitboxValues *)(start + pos);
                    
                    // Валидация значений
                    float vals[10] = {
                        hb->head, hb->torso_1, hb->torso_2,
                        hb->legs_1, hb->legs_2, hb->arms_1,
                        hb->arms_2, hb->chest, hb->stomach, hb->pelvis
                    };
                    
                    BOOL valid = YES;
                    for (int j = 0; j < 10; j++) {
                        if (fabs(vals[j] - ORIGINAL[j]) > 0.001f) {
                            valid = NO;
                            break;
                        }
                    }
                    
                    if (valid) {
                        *offset = pos;
                        *sig_index = sig;
                        log_to_file("✅ Найдена сигнатура #%d", sig);
                        return start + pos;
                    }
                }
            }
        }
    }
    return NULL;
}

#pragma mark - Основной патч
static BOOL apply_patch() {
    @autoreleasepool {
        log_to_file("=== НАЧАЛО ПАТЧА ===");
        
        long offset = 0;
        int sig_index = -1;
        void *addr = find_hitbox(&offset, &sig_index);
        
        if (!addr) {
            log_to_file("❌ Хитбоксы не найдены");
            return NO;
        }
        
        log_to_file("📍 Адрес найден: %p (смещение: 0x%lX, сигнатура: %d)", addr, offset, sig_index);
        
        HitboxValues *hb = (HitboxValues *)addr;
        
        // Создаем резервную копию
        HitboxValues backup;
        memcpy(&backup, hb, sizeof(HitboxValues));
        
        // Сохраняем старые значения для лога
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
        
        // Логируем старые значения
        log_to_file("📊 СТАРЫЕ ЗНАЧЕНИЯ:");
        for (int i = 0; i < 10; i++) {
            log_to_file("  %s: %.3f", NAMES[i], old[i]);
        }
        
        // Создаем новые значения
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
        
        // Безопасная запись
        if (!safe_memory_write(addr, &new_hb, sizeof(HitboxValues))) {
            log_to_file("❌ Ошибка записи в память");
            // Восстанавливаем бэкап
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
        
        // Логируем новые значения
        log_to_file("📊 НОВЫЕ ЗНАЧЕНИЯ (ПРОВЕРЕНО):");
        for (int i = 0; i < 10; i++) {
            log_to_file("  %s: %.3f ✅", NAMES[i], NEW_VALUES[i]);
        }
        
        // Формируем сообщение для UI
        char msg[2048];
        snprintf(msg, sizeof(msg),
                 "✅ ПАТЧ ПРИМЕНЁН УСПЕШНО\n"
                 "─────────────────────────────\n"
                 "📍 Адрес: %p\n"
                 "📌 Смещение: 0x%lX\n"
                 "🔑 Сигнатура: #%d\n"
                 "─────────────────────────────\n\n"
                 "📊 ИЗМЕНЕНИЯ:\n"
                 "HEAD:     %.3f → %.3f %s\n"
                 "TORSO_1:  %.3f → %.3f %s\n"
                 "TORSO_2:  %.3f → %.3f %s\n"
                 "LEGS_1:   %.3f → %.3f %s\n"
                 "LEGS_2:   %.3f → %.3f %s\n"
                 "ARMS_1:   %.3f → %.3f %s\n"
                 "ARMS_2:   %.3f → %.3f %s\n"
                 "CHEST:    %.3f → %.3f %s\n"
                 "STOMACH:  %.3f → %.3f %s\n"
                 "PELVIS:   %.3f → %.3f %s\n"
                 "─────────────────────────────\n"
                 "✅ Все изменения верифицированы!",
                 addr, offset, sig_index,
                 old[0], NEW_VALUES[0], (fabs(old[0] - NEW_VALUES[0]) > 0.001f) ? "✅" : "=",
                 old[1], NEW_VALUES[1], (fabs(old[1] - NEW_VALUES[1]) > 0.001f) ? "✅" : "=",
                 old[2], NEW_VALUES[2], (fabs(old[2] - NEW_VALUES[2]) > 0.001f) ? "✅" : "=",
                 old[3], NEW_VALUES[3], (fabs(old[3] - NEW_VALUES[3]) > 0.001f) ? "✅" : "=",
                 old[4], NEW_VALUES[4], (fabs(old[4] - NEW_VALUES[4]) > 0.001f) ? "✅" : "=",
                 old[5], NEW_VALUES[5], (fabs(old[5] - NEW_VALUES[5]) > 0.001f) ? "✅" : "=",
                 old[6], NEW_VALUES[6], (fabs(old[6] - NEW_VALUES[6]) > 0.001f) ? "✅" : "=",
                 old[7], NEW_VALUES[7], (fabs(old[7] - NEW_VALUES[7]) > 0.001f) ? "✅" : "=",
                 old[8], NEW_VALUES[8], (fabs(old[8] - NEW_VALUES[8]) > 0.001f) ? "✅" : "=",
                 old[9], NEW_VALUES[9], (fabs(old[9] - NEW_VALUES[9]) > 0.001f) ? "✅" : "=");
        
        log_to_file("✅ ПАТЧ УСПЕШНО ПРИМЕНЁН И ВЕРИФИЦИРОВАН");
        show_alert("🎯 ПАТЧ ХИТБОКСОВ", msg, NO);
        
        return YES;
    }
}

#pragma mark - Инициализация с повторными попытками
__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool {
            // Ждем загрузки игры
            [NSThread sleepForTimeInterval:PATCH_DELAY];
            
            int retries = 0;
            BOOL success = NO;
            
            while (retries < MAX_RETRIES && !success) {
                log_to_file("🔄 Попытка патча #%d", retries + 1);
                success = apply_patch();
                
                if (!success) {
                    retries++;
                    if (retries < MAX_RETRIES) {
                        log_to_file("⏳ Повторная попытка через %.1f секунд", RETRY_DELAY);
                        [NSThread sleepForTimeInterval:RETRY_DELAY];
                    }
                }
            }
            
            if (!success) {
                log_to_file("❌ ВСЕ ПОПЫТКИ ПРОВАЛИЛИСЬ (%d)", MAX_RETRIES);
                show_alert("❌ ОШИБКА", 
                          "Не удалось применить патч после всех попыток.\n"
                          "Проверьте логи для подробностей.", YES);
            }
        }
    });
}

#pragma mark - Главный поток (для библиотеки)
int main() {
    @autoreleasepool {
        init();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
