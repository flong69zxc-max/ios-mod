#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <stdlib.h>

// Для показа уведомления в игре
@interface AlertView : NSObject
+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)message;
@end

@implementation AlertView
+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
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
        } else {
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                if (window.rootViewController) {
                    [window.rootViewController presentViewController:alert animated:YES completion:nil];
                    break;
                }
            }
        }
    });
}
@end

typedef struct {
    float head;
    float padding1[7];
    float torso_1;
    float padding2[7];
    float torso_2;
    float padding3[7];
    float legs_1;
    float padding4[7];
    float legs_2;
    float padding5[7];
    float arms_1;
    float padding6[7];
    float arms_2;
    float padding7[7];
    float chest;
    float padding8[7];
    float stomach;
    float padding9[7];
    float pelvis;
} HitboxValues;

const float original_values[10] = {
    0.15, 0.20, 0.25, 0.25, 0.16,
    0.16, 0.20, 0.20, 0.15, 0.15
};

const float new_values[10] = {
    0.225, 0.30, 0.375, 0.375, 0.24,
    0.24, 0.30, 0.30, 0.225, 0.225
};

const char *names[10] = {
    "HEAD", "TORSO_1", "TORSO_2", "LEGS_1", "LEGS_2",
    "ARMS_1", "ARMS_2", "CHEST", "STOMACH", "PELVIS"
};

// Получение пути к папке "Загрузки"
NSString* getDownloadsPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = [paths objectAtIndex:0];
    
    // Создаём папку Downloads, если её нет
    NSString *downloadsPath = [documentsPath stringByAppendingPathComponent:@"Downloads"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if (![fileManager fileExistsAtPath:downloadsPath]) {
        [fileManager createDirectoryAtPath:downloadsPath 
               withIntermediateDirectories:YES 
                                attributes:nil 
                                     error:nil];
    }
    
    // Если не создалась, используем Documents
    if (![fileManager fileExistsAtPath:downloadsPath]) {
        downloadsPath = documentsPath;
    }
    
    return downloadsPath;
}

void log_to_file(const char *msg) {
    @autoreleasepool {
        NSString *downloadsPath = getDownloadsPath();
        NSString *logPath = [downloadsPath stringByAppendingPathComponent:@"hitbox_patch.log"];
        
        FILE *log = fopen([logPath UTF8String], "a");
        if (log) {
            time_t now = time(NULL);
            struct tm *tm = localtime(&now);
            char time_str[20];
            strftime(time_str, sizeof(time_str), "%H:%M:%S", tm);
            
            fprintf(log, "[%s] %s\n", time_str, msg);
            fclose(log);
            printf("✅ Лог записан: %s\n", [logPath UTF8String]);
        } else {
            printf("❌ Не удалось записать лог: %s\n", [logPath UTF8String]);
        }
    }
}

void log_and_notify(const char *status, const char *msg) {
    // В консоль
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char time_str[20];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", tm);
    
    if (strcmp(status, "OK") == 0) {
        printf(GREEN "[%s] ✅ " RESET "%s\n", time_str, msg);
    } else if (strcmp(status, "ERROR") == 0) {
        printf(RED "[%s] ❌ " RESET "%s\n", time_str, msg);
    } else if (strcmp(status, "INFO") == 0) {
        printf(CYAN "[%s] ℹ️ " RESET "%s\n", time_str, msg);
    } else if (strcmp(status, "SUCCESS") == 0) {
        printf(MAGENTA "[%s] 🎯 " RESET "%s\n", time_str, msg);
    } else if (strcmp(status, "WARN") == 0) {
        printf(YELLOW "[%s] ⚠️ " RESET "%s\n", time_str, msg);
    }
    
    // В лог-файл в папку Загрузки
    log_to_file(msg);
}

int patch_file(const char *filepath) {
    log_and_notify("INFO", "🚀 Запуск патча хитбоксов...");
    
    // Проверяем файл
    if (access(filepath, F_OK) != 0) {
        char error_msg[512];
        snprintf(error_msg, sizeof(error_msg), "❌ Файл не найден: %s", filepath);
        log_and_notify("ERROR", error_msg);
        show_game_notification("❌ ОШИБКА", "Файл blackrussia-client не найден!\nПроверь путь.");
        return 1;
    }
    
    log_and_notify("INFO", "📁 Открываю файл...");
    FILE *file = fopen(filepath, "rb+");
    if (!file) {
        log_and_notify("ERROR", "❌ Не удалось открыть файл!");
        show_game_notification("❌ ОШИБКА", "Нет прав на чтение файла!");
        return 1;
    }
    
    // Размер
    fseek(file, 0, SEEK_END);
    long filesize = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    char size_msg[100];
    snprintf(size_msg, sizeof(size_msg), "📊 Размер файла: %ld байт (%.2f MB)", filesize, filesize/1024.0/1024.0);
    log_and_notify("INFO", size_msg);
    
    if (filesize < 0x130) {
        log_and_notify("ERROR", "❌ Файл слишком маленький!");
        show_game_notification("❌ ОШИБКА", "Файл повреждён или не тот файл!");
        fclose(file);
        return 1;
    }
    
    // Читаем
    log_and_notify("INFO", "📖 Читаю файл в память...");
    unsigned char *buffer = (unsigned char*)malloc(filesize);
    if (!buffer) {
        log_and_notify("ERROR", "❌ Не хватает памяти!");
        show_game_notification("❌ ОШИБКА", "Недостаточно памяти!");
        fclose(file);
        return 1;
    }
    
    size_t read_bytes = fread(buffer, 1, filesize, file);
    fclose(file);
    
    char read_msg[100];
    snprintf(read_msg, sizeof(read_msg), "✅ Прочитано байт: %zu", read_bytes);
    log_and_notify("INFO", read_msg);
    
    // Ищем структуру
    log_and_notify("INFO", "🔍 Поиск структуры хитбоксов...");
    int found = 0;
    long pos = 0;
    HitboxValues *hitbox;
    
    for (long i = 0; i <= filesize - sizeof(HitboxValues); i += 4) {
        float *ptr = (float*)(buffer + i);
        if (*ptr == 0.15) {
            hitbox = (HitboxValues*)(buffer + i);
            
            float values[10] = {
                hitbox->head, hitbox->torso_1, hitbox->torso_2,
                hitbox->legs_1, hitbox->legs_2, hitbox->arms_1,
                hitbox->arms_2, hitbox->chest, hitbox->stomach,
                hitbox->pelvis
            };
            
            int match = 1;
            for (int j = 0; j < 10; j++) {
                if (values[j] != original_values[j]) {
                    match = 0;
                    break;
                }
            }
            
            if (match) {
                pos = i;
                found = 1;
                break;
            }
        }
    }
    
    if (!found) {
        log_and_notify("ERROR", "❌ Структура хитбоксов не найдена!");
        show_game_notification("❌ ОШИБКА", 
            "Хитбоксы не найдены!\nВозможно, уже пропатчены.");
        free(buffer);
        return 1;
    }
    
    char found_msg[256];
    snprintf(found_msg, sizeof(found_msg), "✅ Структура найдена по адресу: 0x%lX", pos);
    log_and_notify("SUCCESS", found_msg);
    
    // Показываем найденные значения
    hitbox = (HitboxValues*)(buffer + pos);
    float old_vals[10] = {
        hitbox->head, hitbox->torso_1, hitbox->torso_2,
        hitbox->legs_1, hitbox->legs_2, hitbox->arms_1,
        hitbox->arms_2, hitbox->chest, hitbox->stomach,
        hitbox->pelvis
    };
    
    // Логируем найденные значения
    for (int i = 0; i < 10; i++) {
        char val_msg[100];
        snprintf(val_msg, sizeof(val_msg), "  %s: %.3f (0x%lX)", 
                 names[i], old_vals[i], (long)(pos + i * 0x20));
        log_and_notify("INFO", val_msg);
    }
    
    // Формируем сообщение для игры
    char game_msg[1024];
    snprintf(game_msg, sizeof(game_msg), 
        "📍 Адрес: 0x%lX\n\n"
        "Найдены значения:\n"
        "HEAD: %.3f\n"
        "TORSO: %.3f / %.3f\n"
        "LEGS: %.3f / %.3f\n"
        "ARMS: %.3f / %.3f\n"
        "CHEST: %.3f\n"
        "STOMACH: %.3f\n"
        "PELVIS: %.3f\n\n"
        "🔄 Применяем патч...",
        pos,
        old_vals[0], old_vals[1], old_vals[2],
        old_vals[3], old_vals[4], old_vals[5],
        old_vals[6], old_vals[7], old_vals[8],
        old_vals[9]);
    
    show_game_notification("🎯 ХИТБОКСЫ НАЙДЕНЫ", game_msg);
    
    // Бэкап
    log_and_notify("INFO", "💾 Создаю бэкап...");
    char backup_path[512];
    snprintf(backup_path, sizeof(backup_path), "%s.backup", filepath);
    
    FILE *backup = fopen(backup_path, "wb");
    if (backup) {
        fwrite(buffer, 1, filesize, backup);
        fclose(backup);
        log_and_notify("OK", "✅ Бэкап создан");
    } else {
        log_and_notify("WARN", "⚠️ Не удалось создать бэкап!");
    }
    
    // Применяем патч
    log_and_notify("INFO", "🛠 Применяю патч...");
    hitbox->head = new_values[0];
    hitbox->torso_1 = new_values[1];
    hitbox->torso_2 = new_values[2];
    hitbox->legs_1 = new_values[3];
    hitbox->legs_2 = new_values[4];
    hitbox->arms_1 = new_values[5];
    hitbox->arms_2 = new_values[6];
    hitbox->chest = new_values[7];
    hitbox->stomach = new_values[8];
    hitbox->pelvis = new_values[9];
    
    // Записываем обратно
    file = fopen(filepath, "wb");
    if (!file) {
        log_and_notify("ERROR", "❌ Не удалось открыть для записи!");
        show_game_notification("❌ ОШИБКА", "Нет прав на запись!");
        free(buffer);
        return 1;
    }
    
    size_t written = fwrite(buffer, 1, filesize, file);
    fclose(file);
    free(buffer);
    
    char write_msg[100];
    snprintf(write_msg, sizeof(write_msg), "✅ Записано байт: %zu", written);
    log_and_notify("INFO", write_msg);
    
    // Логируем новые значения
    for (int i = 0; i < 10; i++) {
        char val_msg[100];
        snprintf(val_msg, sizeof(val_msg), "  %s: %.3f → %.3f", 
                 names[i], old_vals[i], new_values[i]);
        log_and_notify("OK", val_msg);
    }
    
    // Формируем финальное сообщение
    char result_msg[1024];
    snprintf(result_msg, sizeof(result_msg),
        "✅ ПАТЧ ПРИМЕНЁН!\n\n"
        "📍 Адрес: 0x%lX\n\n"
        "Новые значения:\n"
        "HEAD: %.3f (было %.3f)\n"
        "TORSO_1: %.3f (было %.3f)\n"
        "TORSO_2: %.3f (было %.3f)\n"
        "LEGS_1: %.3f (было %.3f)\n"
        "LEGS_2: %.3f (было %.3f)\n"
        "ARMS_1: %.3f (было %.3f)\n"
        "ARMS_2: %.3f (было %.3f)\n"
        "CHEST: %.3f (было %.3f)\n"
        "STOMACH: %.3f (было %.3f)\n"
        "PELVIS: %.3f (было %.3f)\n\n"
        "📁 Лог: Загрузки/hitbox_patch.log\n"
        "💾 Бэкап: %s.backup",
        pos,
        new_values[0], old_vals[0],
        new_values[1], old_vals[1],
        new_values[2], old_vals[2],
        new_values[3], old_vals[3],
        new_values[4], old_vals[4],
        new_values[5], old_vals[5],
        new_values[6], old_vals[6],
        new_values[7], old_vals[7],
        new_values[8], old_vals[8],
        new_values[9], old_vals[9],
        filepath);
    
    log_and_notify("SUCCESS", "🎉 Патч успешно применён!");
    show_game_notification("🎉 УСПЕХ!", result_msg);
    
    return 0;
}

// Точка входа для iOS
__attribute__((constructor)) void init() {
    @autoreleasepool {
        printf("\n═══════════════════════════════════════════════\n");
        printf("   HITBOX PATCHER v3.0 — Logs to Downloads\n");
        printf("═══════════════════════════════════════════════\n\n");
        
        // Показываем путь к логу
        NSString *downloadsPath = getDownloadsPath();
        NSString *logPath = [downloadsPath stringByAppendingPathComponent:@"hitbox_patch.log"];
        printf("📁 Лог будет сохранён: %s\n\n", [logPath UTF8String]);
        
        // Путь по умолчанию
        const char *filepath = "Payload/BlackRussia.app/Frameworks/blackrussia-client.framework/blackrussia-client";
        
        // Проверяем, есть ли файл
        if (access(filepath, F_OK) == 0) {
            patch_file(filepath);
        } else {
            char error_msg[512];
            snprintf(error_msg, sizeof(error_msg), "❌ Файл не найден: %s", filepath);
            log_and_notify("ERROR", error_msg);
            show_game_notification("❌ ОШИБКА", 
                "Файл не найден!\n"
                "Путь: Payload/BlackRussia.app/Frameworks/\n"
                "blackrussia-client.framework/blackrussia-client");
        }
        
        printf("\n═══════════════════════════════════════════════\n");
        printf("📁 Проверь лог в папке Загрузки\n");
        printf("═══════════════════════════════════════════════\n\n");
    }
}

int main(int argc, const char * argv[]) {
    init();
    return 0;
}
