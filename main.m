#import <Foundation/Foundation.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

// Структура значений (10 штук с шагом 0x20)
typedef struct {
    float head;        // 0x00 - 0.15
    float padding1[7]; // 0x04-0x1F
    float torso_1;     // 0x20 - 0.20
    float padding2[7]; // 0x24-0x3F
    float torso_2;     // 0x40 - 0.25
    float padding3[7]; // 0x44-0x5F
    float legs_1;      // 0x60 - 0.25
    float padding4[7]; // 0x64-0x7F
    float legs_2;      // 0x80 - 0.16
    float padding5[7]; // 0x84-0x9F
    float arms_1;      // 0xA0 - 0.16
    float padding6[7]; // 0xA4-0xBF
    float arms_2;      // 0xC0 - 0.20
    float padding7[7]; // 0xC4-0xDF
    float chest;       // 0xE0 - 0.20
    float padding8[7]; // 0xE4-0xFF
    float stomach;     // 0x100 - 0.15
    float padding9[7]; // 0x104-0x11F
    float pelvis;      // 0x120 - 0.15
} HitboxValues;

// Оригинальные значения (float в HEX)
const float original_values[10] = {
    0.15, 0.20, 0.25, 0.25, 0.16,
    0.16, 0.20, 0.20, 0.15, 0.15
};

// Новые значения
const float new_values[10] = {
    0.225, 0.30, 0.375, 0.375, 0.24,
    0.24, 0.30, 0.30, 0.225, 0.225
};

// Сигнатура для поиска (HEAD = 0.15 в float)
const float signature = 0.15;

void log_message(const char *msg) {
    printf("[HITBOX PATCH] %s\n", msg);
    
    // Пишем в лог-файл
    FILE *log = fopen("/var/mobile/hitbox_patch.log", "a");
    if (log) {
        fprintf(log, "[%s] %s\n", [[[NSDate date] description] UTF8String], msg);
        fclose(log);
    }
}

int patch_file(const char *filepath) {
    FILE *file = fopen(filepath, "rb+");
    if (!file) {
        log_message("❌ Не удалось открыть файл!");
        return 1;
    }
    
    // Получаем размер файла
    fseek(file, 0, SEEK_END);
    long filesize = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    if (filesize < 0x130) {
        log_message("❌ Файл слишком маленький!");
        fclose(file);
        return 1;
    }
    
    // Читаем весь файл в память
    unsigned char *buffer = (unsigned char*)malloc(filesize);
    if (!buffer) {
        log_message("❌ Не удалось выделить память!");
        fclose(file);
        return 1;
    }
    
    fread(buffer, 1, filesize, file);
    fclose(file);
    
    // Ищем сигнатуру
    int found = 0;
    long pos = 0;
    HitboxValues *hitbox;
    
    // Ищем HEAD (0.15) и проверяем структуру
    for (long i = 0; i <= filesize - sizeof(HitboxValues); i += 4) {
        float *ptr = (float*)(buffer + i);
        if (*ptr == signature) {
            // Проверяем, что все 10 значений совпадают с шагом 0x20
            hitbox = (HitboxValues*)(buffer + i);
            
            float values[10] = {
                hitbox->head,
                hitbox->torso_1,
                hitbox->torso_2,
                hitbox->legs_1,
                hitbox->legs_2,
                hitbox->arms_1,
                hitbox->arms_2,
                hitbox->chest,
                hitbox->stomach,
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
        log_message("❌ Структура хитбоксов не найдена!");
        free(buffer);
        return 1;
    }
    
    log_message("✅ Найдена структура хитбоксов!");
    
    // Логируем найденные значения
    hitbox = (HitboxValues*)(buffer + pos);
    float old_vals[10] = {
        hitbox->head, hitbox->torso_1, hitbox->torso_2, hitbox->legs_1, hitbox->legs_2,
        hitbox->arms_1, hitbox->arms_2, hitbox->chest, hitbox->stomach, hitbox->pelvis
    };
    
    char log_buf[512];
    snprintf(log_buf, sizeof(log_buf), "📊 Найдены значения: HEAD=%.3f TORSO=%.3f/%.3f LEGS=%.3f/%.3f ARMS=%.3f/%.3f CHEST=%.3f STOMACH=%.3f PELVIS=%.3f",
             old_vals[0], old_vals[1], old_vals[2], old_vals[3], old_vals[4],
             old_vals[5], old_vals[6], old_vals[7], old_vals[8], old_vals[9]);
    log_message(log_buf);
    
    // Создаём бэкап
    char backup_path[512];
    snprintf(backup_path, sizeof(backup_path), "%s.backup", filepath);
    
    FILE *backup = fopen(backup_path, "wb");
    if (backup) {
        fwrite(buffer, 1, filesize, backup);
        fclose(backup);
        log_message("💾 Создан бэкап: blackrussia-client.backup");
    } else {
        log_message("⚠️ Не удалось создать бэкап!");
    }
    
    // Заменяем значения
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
        log_message("❌ Не удалось открыть файл для записи!");
        free(buffer);
        return 1;
    }
    
    fwrite(buffer, 1, filesize, file);
    fclose(file);
    free(buffer);
    
    // Логируем новые значения
    snprintf(log_buf, sizeof(log_buf), "✅ ПАТЧ ПРИМЕНЁН! Новые значения: HEAD=%.3f TORSO=%.3f/%.3f LEGS=%.3f/%.3f ARMS=%.3f/%.3f CHEST=%.3f STOMACH=%.3f PELVIS=%.3f",
             new_values[0], new_values[1], new_values[2], new_values[3], new_values[4],
             new_values[5], new_values[6], new_values[7], new_values[8], new_values[9]);
    log_message(log_buf);
    
    log_message("🎯 Патч успешно применён!");
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        const char *filepath;
        
        if (argc > 1) {
            filepath = argv[1];
        } else {
            // Путь по умолчанию
            filepath = "Payload/BlackRussia.app/Frameworks/blackrussia-client.framework/blackrussia-client";
        }
        
        log_message("🚀 Запуск патча хитбоксов...");
        
        char log_buf[256];
        snprintf(log_buf, sizeof(log_buf), "📁 Файл: %s", filepath);
        log_message(log_buf);
        
        // Проверяем существование файла
        if (access(filepath, F_OK) != 0) {
            log_message("❌ Файл не найден! Проверь путь.");
            return 1;
        }
        
        int result = patch_file(filepath);
        
        if (result == 0) {
            log_message("✅ Всё готово! Можно запускать игру.");
        } else {
            log_message("❌ Ошибка при патче!");
        }
        
        return result;
    }
}
