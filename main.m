#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <stdlib.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>

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
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) {
                        if (w.rootViewController) {
                            root = w.rootViewController;
                            break;
                        }
                    }
                }
            }
        }
        if (!root) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.rootViewController) { root = w.rootViewController; break; }
            }
        }
        if (root) [root presentViewController:alert animated:YES completion:nil];
    });
}
@end

static NSString* savesPath(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *saves = [doc stringByAppendingPathComponent:@"saves"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:saves]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:saves] ? saves : doc;
}

static void logMsg(const char *msg) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char ts[20];
    strftime(ts, sizeof(ts), "%H:%M:%S", tm);
    
    printf("[%s] %s\n", ts, msg);
    
    NSString *logPath = [savesPath() stringByAppendingPathComponent:@"hitbox_patch.log"];
    FILE *f = fopen([logPath UTF8String], "a");
    if (f) { fprintf(f, "[%s] %s\n", ts, msg); fclose(f); }
}

static void notify(const char *title, const char *msg) {
    [AlertView show:[NSString stringWithUTF8String:title] msg:[NSString stringWithUTF8String:msg]];
}

static int patch(const char *path) {
    logMsg("🚀 Запуск патча");
    logMsg(path);
    
    if (access(path, F_OK)) {
        logMsg("❌ Файл не найден");
        return 1;
    }
    
    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) {
        logMsg("❌ Не удалось открыть файл");
        notify("❌ ОШИБКА", "Нет прав на чтение");
        return 1;
    }
    
    struct stat st;
    fstat(fd, &st);
    long size = st.st_size;
    
    if (size < 0x130) {
        logMsg("❌ Файл слишком маленький");
        close(fd);
        return 1;
    }
    
    unsigned char *buf = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (buf == MAP_FAILED) {
        logMsg("❌ mmap не удался");
        close(fd);
        return 1;
    }
    
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
        logMsg("❌ Структура не найдена");
        notify("❌ ОШИБКА", "Хитбоксы не найдены");
        munmap(buf, size);
        close(fd);
        return 1;
    }
    
    hb = (HitboxValues*)(buf + pos);
    float old[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
    
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "✅ Найдено по адресу: 0x%lX", pos);
    logMsg(tmp);
    
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f (0x%lX)", names[i], old[i], (long)(pos + i * 0x20));
        logMsg(tmp);
    }
    
    char gameMsg[1024];
    snprintf(gameMsg, sizeof(gameMsg), "📍 Адрес: 0x%lX\n\nНайдены значения:\nHEAD: %.3f\nTORSO: %.3f / %.3f\nLEGS: %.3f / %.3f\nARMS: %.3f / %.3f\nCHEST: %.3f\nSTOMACH: %.3f\nPELVIS: %.3f\n\n🔄 Применяем патч...", pos, old[0], old[1], old[2], old[3], old[4], old[5], old[6], old[7], old[8], old[9]);
    notify("🎯 ХИТБОКСЫ НАЙДЕНЫ", gameMsg);
    
    char backup[512];
    snprintf(backup, sizeof(backup), "%s.backup", path);
    int backup_fd = open(backup, O_WRONLY | O_CREAT, 0644);
    if (backup_fd >= 0) {
        write(backup_fd, buf, size);
        close(backup_fd);
        logMsg("💾 Бэкап создан");
    } else {
        logMsg("⚠️ Бэкап не создан");
    }
    
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
    
    if (msync(buf, size, MS_SYNC) != 0) {
        logMsg("⚠️ msync не удался");
    }
    
    munmap(buf, size);
    close(fd);
    
    logMsg("📊 Изменения:");
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f → %.3f", names[i], old[i], news[i]);
        logMsg(tmp);
    }
    
    snprintf(gameMsg, sizeof(gameMsg), "✅ ПАТЧ ПРИМЕНЁН!\n\n📍 Адрес: 0x%lX\n\nНовые значения:\nHEAD: %.3f (было %.3f)\nTORSO_1: %.3f (было %.3f)\nTORSO_2: %.3f (было %.3f)\nLEGS_1: %.3f (было %.3f)\nLEGS_2: %.3f (было %.3f)\nARMS_1: %.3f (было %.3f)\nARMS_2: %.3f (было %.3f)\nCHEST: %.3f (было %.3f)\nSTOMACH: %.3f (было %.3f)\nPELVIS: %.3f (было %.3f)\n\n📁 Лог: saves/hitbox_patch.log\n\n⚠️ ПЕРЕЗАПУСТИ ИГРУ!", pos, news[0], old[0], news[1], old[1], news[2], old[2], news[3], old[3], news[4], old[4], news[5], old[5], news[6], old[6], news[7], old[7], news[8], old[8], news[9], old[9]);
    
    logMsg("🎉 Патч применён");
    notify("🎉 УСПЕХ!", gameMsg);
    return 0;
}

static void findAndPatch(void) {
    @autoreleasepool {
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        logMsg([[NSString stringWithFormat:@"Bundle: %@", bundlePath] UTF8String]);
        
        NSFileManager *fm = [NSFileManager defaultManager];
        
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bundlePath];
        NSString *file;
        while ((file = [enumerator nextObject])) {
            if ([file hasSuffix:@"blackrussia-client"] && ![file containsString:@".dSYM"]) {
                NSString *fullPath = [bundlePath stringByAppendingPathComponent:file];
                logMsg([[NSString stringWithFormat:@"✅ Найден файл: %@", fullPath] UTF8String]);
                patch([fullPath UTF8String]);
                return;
            }
        }
        
        const char *paths[] = {
            "BrBase.app/Frameworks/blackrussia-client.framework/blackrussia-client",
            "Payload/BrBase.app/Frameworks/blackrussia-client.framework/blackrussia-client",
            NULL
        };
        
        for (int i = 0; paths[i] != NULL; i++) {
            if (access(paths[i], F_OK) == 0) {
                logMsg([[NSString stringWithFormat:@"✅ Найден файл: %s", paths[i]] UTF8String]);
                patch(paths[i]);
                return;
            }
        }
        
        logMsg("❌ Файл не найден нигде");
        notify("❌ ОШИБКА", "Файл не найден\nПроверь лог в папке saves");
    }
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        printf("\n═══════════════════════════════════════════════\n");
        printf("   HITBOX PATCHER v4.0\n");
        printf("═══════════════════════════════════════════════\n\n");
        
        findAndPatch();
        
        printf("\n═══════════════════════════════════════════════\n");
        printf("📁 Лог: saves/hitbox_patch.log\n");
        printf("═══════════════════════════════════════════════\n\n");
    }
}

int main(void) { init(); return 0; }
