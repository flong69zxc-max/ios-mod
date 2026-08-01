#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <stdlib.h>

#define RESET   "\033[0m"
#define RED     "\033[31m"
#define GREEN   "\033[32m"
#define YELLOW  "\033[33m"
#define CYAN    "\033[36m"
#define MAGENTA "\033[35m"

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

static const float orig[10] = {0.15f, 0.20f, 0.25f, 0.25f, 0.16f, 0.16f, 0.20f, 0.20f, 0.15f, 0.15f};
static const float news[10] = {0.225f, 0.30f, 0.375f, 0.375f, 0.24f, 0.24f, 0.30f, 0.30f, 0.225f, 0.225f};
static const char *names[10] = {"HEAD", "TORSO_1", "TORSO_2", "LEGS_1", "LEGS_2", "ARMS_1", "ARMS_2", "CHEST", "STOMACH", "PELVIS"};

@interface AlertView : NSObject @end
@implementation AlertView
+ (void)show:(NSString *)title msg:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *root = nil;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
            if (scene) root = scene.windows.firstObject.rootViewController;
        }
        if (!root) root = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (!root) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.rootViewController) { root = w.rootViewController; break; }
            }
        }
        if (root) [root presentViewController:alert animated:YES completion:nil];
    });
}
@end

static NSString* downloadsPath(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dl = [doc stringByAppendingPathComponent:@"Downloads"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dl]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dl withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:dl] ? dl : doc;
}

static void logMsg(const char *type, const char *msg) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char ts[20];
    strftime(ts, sizeof(ts), "%H:%M:%S", tm);
    
    if (!strcmp(type, "OK")) printf(GREEN "[%s] ✅ %s\n" RESET, ts, msg);
    else if (!strcmp(type, "ERROR")) printf(RED "[%s] ❌ %s\n" RESET, ts, msg);
    else if (!strcmp(type, "INFO")) printf(CYAN "[%s] ℹ️ %s\n" RESET, ts, msg);
    else if (!strcmp(type, "SUCCESS")) printf(MAGENTA "[%s] 🎯 %s\n" RESET, ts, msg);
    else if (!strcmp(type, "WARN")) printf(YELLOW "[%s] ⚠️ %s\n" RESET, ts, msg);
    
    NSString *logPath = [downloadsPath() stringByAppendingPathComponent:@"hitbox_patch.log"];
    FILE *f = fopen([logPath UTF8String], "a");
    if (f) { fprintf(f, "[%s] %s\n", ts, msg); fclose(f); }
}

static void notify(const char *title, const char *msg) {
    [AlertView show:[NSString stringWithUTF8String:title] msg:[NSString stringWithUTF8String:msg]];
}

static int patch(const char *path) {
    logMsg("INFO", "🚀 Запуск патча");
    
    if (access(path, F_OK)) {
        logMsg("ERROR", "Файл не найден");
        notify("❌ ОШИБКА", "Файл не найден");
        return 1;
    }
    
    FILE *f = fopen(path, "rb+");
    if (!f) {
        logMsg("ERROR", "Не удалось открыть файл");
        notify("❌ ОШИБКА", "Нет прав на чтение");
        return 1;
    }
    
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    if (size < 0x130) {
        logMsg("ERROR", "Файл слишком маленький");
        fclose(f);
        return 1;
    }
    
    unsigned char *buf = malloc(size);
    if (!buf) {
        logMsg("ERROR", "Не хватает памяти");
        fclose(f);
        return 1;
    }
    
    fread(buf, 1, size, f);
    fclose(f);
    
    unsigned char sig[4] = {0x9A, 0x99, 0x19, 0x3E};
    long pos = -1;
    HitboxValues *hb = NULL;
    
    for (long i = 0; i <= size - sizeof(HitboxValues); i += 4) {
        if (memcmp(buf + i, sig, 4) == 0) {
            hb = (HitboxValues*)(buf + i);
            float vals[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
            int match = 1;
            for (int j = 0; j < 10; j++) {
                if (fabs(vals[j] - orig[j]) > 0.001f) { match = 0; break; }
            }
            if (match) { pos = i; break; }
        }
    }
    
    if (pos < 0) {
        logMsg("ERROR", "Структура не найдена");
        notify("❌ ОШИБКА", "Хитбоксы не найдены");
        free(buf);
        return 1;
    }
    
    hb = (HitboxValues*)(buf + pos);
    float old[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
    
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "✅ Найдено по адресу: 0x%lX", pos);
    logMsg("SUCCESS", tmp);
    
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f", names[i], old[i]);
        logMsg("INFO", tmp);
    }
    
    char gameMsg[1024];
    snprintf(gameMsg, sizeof(gameMsg), "📍 Адрес: 0x%lX\n\nНайдены значения:\nHEAD: %.3f\nTORSO: %.3f / %.3f\nLEGS: %.3f / %.3f\nARMS: %.3f / %.3f\nCHEST: %.3f\nSTOMACH: %.3f\nPELVIS: %.3f\n\n🔄 Применяем патч...", pos, old[0], old[1], old[2], old[3], old[4], old[5], old[6], old[7], old[8], old[9]);
    notify("🎯 ХИТБОКСЫ НАЙДЕНЫ", gameMsg);
    
    char backup[512];
    snprintf(backup, sizeof(backup), "%s.backup", path);
    FILE *b = fopen(backup, "wb");
    if (b) { fwrite(buf, 1, size, b); fclose(b); logMsg("OK", "💾 Бэкап создан"); }
    else logMsg("WARN", "⚠️ Бэкап не создан");
    
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
    
    f = fopen(path, "wb");
    if (!f) {
        logMsg("ERROR", "Не удалось открыть для записи");
        notify("❌ ОШИБКА", "Нет прав на запись");
        free(buf);
        return 1;
    }
    
    fwrite(buf, 1, size, f);
    fclose(f);
    free(buf);
    
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f → %.3f", names[i], old[i], news[i]);
        logMsg("OK", tmp);
    }
    
    snprintf(gameMsg, sizeof(gameMsg), "✅ ПАТЧ ПРИМЕНЁН!\n\n📍 Адрес: 0x%lX\n\nНовые значения:\nHEAD: %.3f (было %.3f)\nTORSO_1: %.3f (было %.3f)\nTORSO_2: %.3f (было %.3f)\nLEGS_1: %.3f (было %.3f)\nLEGS_2: %.3f (было %.3f)\nARMS_1: %.3f (было %.3f)\nARMS_2: %.3f (было %.3f)\nCHEST: %.3f (было %.3f)\nSTOMACH: %.3f (было %.3f)\nPELVIS: %.3f (было %.3f)\n\n📁 Лог: Загрузки/hitbox_patch.log", pos, news[0], old[0], news[1], old[1], news[2], old[2], news[3], old[3], news[4], old[4], news[5], old[5], news[6], old[6], news[7], old[7], news[8], old[8], news[9], old[9]);
    
    logMsg("SUCCESS", "🎉 Патч применён");
    notify("🎉 УСПЕХ!", gameMsg);
    return 0;
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        printf("\n═══════════════════════════════════════════════\n");
        printf("   HITBOX PATCHER v3.0\n");
        printf("═══════════════════════════════════════════════\n\n");
        
        const char *path = "Payload/BrBase.app/Frameworks/blackrussia-client.framework/blackrussia-client";
        
        if (access(path, F_OK) == 0) {
            patch(path);
        } else {
            logMsg("ERROR", "Файл не найден");
            notify("❌ ОШИБКА", "Файл не найден\nPayload/BrBase.app/Frameworks/\nblackrussia-client.framework/\nblackrussia-client");
        }
        
        printf("\n═══════════════════════════════════════════════\n");
        printf("📁 Лог: Загрузки/hitbox_patch.log\n");
        printf("═══════════════════════════════════════════════\n\n");
    }
}

int main(void) { init(); return 0; }
