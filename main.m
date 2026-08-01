#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

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

static const float orig[10] = {0.15f,0.20f,0.25f,0.25f,0.16f,0.16f,0.20f,0.20f,0.15f,0.15f};
static const float news[10] = {0.225f,0.30f,0.375f,0.375f,0.24f,0.24f,0.30f,0.30f,0.225f,0.225f};
static const char *names[10] = {"HEAD","TORSO_1","TORSO_2","LEGS_1","LEGS_2","ARMS_1","ARMS_2","CHEST","STOMACH","PELVIS"};

// Глобальный указатель на окно для HUD
static UIWindow *hudWindow = nil;
static UILabel *hudLabel = nil;

// Путь к папке Downloads
static NSString* getDownloadsPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = [paths firstObject];
    NSString *downloads = [doc stringByAppendingPathComponent:@"Downloads"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:downloads]) {
        [fm createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return downloads;
}

// Логирование с временем
static void log_to_file(const char *msg) {
    NSString *logPath = [getDownloadsPath() stringByAppendingPathComponent:@"hitbox_patch.log"];
    FILE *f = fopen([logPath UTF8String], "a");
    if (f) {
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        char ts[20];
        strftime(ts, sizeof(ts), "%H:%M:%S", tm);
        fprintf(f, "[%s] %s\n", ts, msg);
        fclose(f);
    }
}

// Создание HUD-окна с анимацией
static void showHUD(const char *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!hudWindow) {
            // Создаём окно поверх всех
            hudWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            hudWindow.windowLevel = UIWindowLevelAlert + 1;
            hudWindow.backgroundColor = [UIColor clearColor];
            hudWindow.userInteractionEnabled = NO;
            
            // Фон с прозрачностью
            UIView *bg = [[UIView alloc] initWithFrame:hudWindow.bounds];
            bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
            bg.layer.cornerRadius = 20;
            bg.clipsToBounds = YES;
            [hudWindow addSubview:bg];
            
            // Лейбл
            hudLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, hudWindow.bounds.size.width - 40, 100)];
            hudLabel.textColor = [UIColor whiteColor];
            hudLabel.font = [UIFont boldSystemFontOfSize:20];
            hudLabel.textAlignment = NSTextAlignmentCenter;
            hudLabel.numberOfLines = 0;
            [bg addSubview:hudLabel];
            
            hudWindow.hidden = NO;
        }
        
        // Анимируем смену текста (плавное исчезновение/появление)
        [UIView transitionWithView:hudLabel duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            hudLabel.text = [NSString stringWithUTF8String:text];
        } completion:nil];
    });
}

// Скрыть HUD через 3 секунды после успеха
static void hideHUD(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (hudWindow) {
            [UIView animateWithDuration:0.5 animations:^{
                hudWindow.alpha = 0;
            } completion:^(BOOL finished) {
                hudWindow.hidden = YES;
                hudWindow = nil;
            }];
        }
    });
}

// Поиск структуры в памяти с детальным логированием
static void* find_hitbox(long *out_offset, uintptr_t *out_base, const char **out_libname) {
    uint32_t count = _dyld_image_count();
    unsigned char sig[4] = {0x9A,0x99,0x19,0x3E};
    
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        
        // Ищем только в нужных библиотеках
        if (!strstr(name, "blackrussia-client") && !strstr(name, "BrBase")) continue;
        
        log_to_file("Сканируем библиотеку:");
        log_to_file(name);
        
        void *base = (void*)_dyld_get_image_vmaddr_slide(i);
        struct mach_header_64 *header = (struct mach_header_64*)_dyld_get_image_header(i);
        if (!header) continue;
        
        // Получаем размер сегментов DATA и TEXT
        uintptr_t size = 0;
        struct load_command *cmd = (struct load_command*)((uintptr_t)header + sizeof(struct mach_header_64));
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64*)cmd;
                if (strcmp(seg->segname, "__DATA") == 0 || strcmp(seg->segname, "__TEXT") == 0) {
                    size += seg->vmsize;
                    char buf[256];
                    snprintf(buf, sizeof(buf), "Сегмент %s размер: 0x%llX", seg->segname, seg->vmsize);
                    log_to_file(buf);
                }
            }
            cmd = (struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
        }
        
        unsigned char *start = (unsigned char*)base;
        for (uintptr_t i = 0; i < size - 4; i += 4) {
            if (memcmp(start + i, sig, 4) == 0) {
                HitboxValues *hb = (HitboxValues*)(start + i);
                float vals[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
                int ok = 1;
                for (int j = 0; j < 10; j++) {
                    if (fabs(vals[j] - orig[j]) > 0.001f) { ok = 0; break; }
                }
                if (ok) {
                    *out_offset = i;
                    *out_base = (uintptr_t)base;
                    *out_libname = name;
                    char buf[256];
                    snprintf(buf, sizeof(buf), "Найдена структура по смещению 0x%lX в библиотеке %s", i, name);
                    log_to_file(buf);
                    return start + i;
                }
            }
        }
    }
    return NULL;
}

// Основная функция патча
static void patch(void) {
    log_to_file("=== ЗАПУСК ПАТЧА ===");
    showHUD("Загрузка...");
    
    // Небольшая задержка для инициализации
    sleep(1);
    
    showHUD("Инициализация...");
    log_to_file("Инициализация поиска");
    
    long offset = 0;
    uintptr_t base = 0;
    const char *libname = NULL;
    void *addr = find_hitbox(&offset, &base, &libname);
    
    if (!addr) {
        log_to_file("❌ Хитбоксы не найдены");
        showHUD("Ошибка: хитбоксы не найдены");
        sleep(1);
        hideHUD();
        return;
    }
    
    showHUD("Найдено! Применяем...");
    log_to_file("✅ Структура найдена");
    
    HitboxValues *hb = (HitboxValues*)addr;
    float old[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
    
    // Логируем старые значения с адресами
    log_to_file("Старые значения:");
    for (int i = 0; i < 10; i++) {
        uintptr_t field_addr = (uintptr_t)addr + i * 0x20;
        char buf[128];
        snprintf(buf, sizeof(buf), "  %s: %.3f (адрес: 0x%lX)", names[i], old[i], field_addr);
        log_to_file(buf);
    }
    
    // Патчим
    hb->head = news[0];
    hb->torso_1 = news[1];
    hb->torso_2 = news[2];
    hb->legs_1 = news[3];
    hb->legs_2 = news[4];
    hb->arms_1 = news[5];
    hb->arms_2 = news[6];
    hb->chest = news[7];
    hb->stomach = news[8];
    hb->pelvis = news[9];
    
    // Логируем новые значения
    log_to_file("Новые значения:");
    for (int i = 0; i < 10; i++) {
        uintptr_t field_addr = (uintptr_t)addr + i * 0x20;
        char buf[128];
        snprintf(buf, sizeof(buf), "  %s: %.3f (адрес: 0x%lX)", names[i], news[i], field_addr);
        log_to_file(buf);
    }
    
    log_to_file("✅ Патч успешно применён");
    log_to_file("=== КОНЕЦ ПАТЧА ===");
    
    showHUD("Успех! Хитбоксы заменены");
    hideHUD();
}

// Конструктор – запускается при загрузке dylib
__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @autoreleasepool {
            patch();
        }
    });
}

int main() {
    @autoreleasepool {
        patch();
        while(1) sleep(1);
    }
    return 0;
}
