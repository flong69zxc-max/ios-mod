#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

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

static void* findInMemory(const char *filename, const unsigned char *sig, size_t sig_len, long *offset) {
    // Ищем образ в памяти
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, filename)) {
            void *base = (void*)_dyld_get_image_vmaddr_slide(i);
            struct mach_header_64 *header = (struct mach_header_64*)_dyld_get_image_header(i);
            if (!header) continue;
            
            // Получаем размер сегмента
            uintptr_t size = 0;
            struct load_command *cmd = (struct load_command*)((uintptr_t)header + sizeof(struct mach_header_64));
            for (uint32_t j = 0; j < header->ncmds; j++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    struct segment_command_64 *seg = (struct segment_command_64*)cmd;
                    if (strcmp(seg->segname, "__DATA") == 0 || strcmp(seg->segname, "__TEXT") == 0) {
                        size += seg->vmsize;
                    }
                }
                cmd = (struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
            }
            
            // Ищем сигнатуру в памяти
            unsigned char *start = (unsigned char*)base;
            for (uintptr_t i = 0; i < size - sig_len; i += 4) {
                if (memcmp(start + i, sig, sig_len) == 0) {
                    // Проверяем структуру
                    HitboxValues *hb = (HitboxValues*)(start + i);
                    float vals[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
                    int match = 1;
                    for (int j = 0; j < 10; j++) {
                        if (fabs(vals[j] - orig[j]) > 0.001f) { match = 0; break; }
                    }
                    if (match) {
                        *offset = i;
                        return start + i;
                    }
                }
            }
        }
    }
    return NULL;
}

static int patchInMemory(void) {
    logMsg("🚀 Поиск хитбоксов в памяти");
    
    unsigned char sig[4] = {0x9A, 0x99, 0x19, 0x3E};
    long offset = 0;
    
    // Ищем в загруженных библиотеках
    void *addr = findInMemory("blackrussia-client", sig, 4, &offset);
    if (!addr) {
        // Пробуем в основном бинарнике
        addr = findInMemory("BrBase", sig, 4, &offset);
    }
    
    if (!addr) {
        logMsg("❌ Структура не найдена в памяти");
        notify("❌ ОШИБКА", "Хитбоксы не найдены");
        return 1;
    }
    
    HitboxValues *hb = (HitboxValues*)addr;
    float old[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
    
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "✅ Найдено в памяти по адресу: %p (offset: 0x%lX)", addr, offset);
    logMsg(tmp);
    
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f", names[i], old[i]);
        logMsg(tmp);
    }
    
    char gameMsg[1024];
    snprintf(gameMsg, sizeof(gameMsg), "📍 Адрес: %p\n\nНайдены значения:\nHEAD: %.3f\nTORSO: %.3f / %.3f\nLEGS: %.3f / %.3f\nARMS: %.3f / %.3f\nCHEST: %.3f\nSTOMACH: %.3f\nPELVIS: %.3f\n\n🔄 Применяем патч в памяти...", addr, old[0], old[1], old[2], old[3], old[4], old[5], old[6], old[7], old[8], old[9]);
    notify("🎯 ХИТБОКСЫ НАЙДЕНЫ", gameMsg);
    
    // Патчим в памяти (не на диске!)
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
    
    logMsg("📊 Изменения:");
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f → %.3f", names[i], old[i], news[i]);
        logMsg(tmp);
    }
    
    snprintf(gameMsg, sizeof(gameMsg), "✅ ПАТЧ ПРИМЕНЁН В ПАМЯТИ!\n\n📍 Адрес: %p\n\nНовые значения:\nHEAD: %.3f (было %.3f)\nTORSO_1: %.3f (было %.3f)\nTORSO_2: %.3f (было %.3f)\nLEGS_1: %.3f (было %.3f)\nLEGS_2: %.3f (было %.3f)\nARMS_1: %.3f (было %.3f)\nARMS_2: %.3f (было %.3f)\nCHEST: %.3f (было %.3f)\nSTOMACH: %.3f (было %.3f)\nPELVIS: %.3f (было %.3f)\n\n📁 Лог: saves/hitbox_patch.log\n\n✅ ИГРАЙ! ВСЁ РАБОТАЕТ!", addr, news[0], old[0], news[1], old[1], news[2], old[2], news[3], old[3], news[4], old[4], news[5], old[5], news[6], old[6], news[7], old[7], news[8], old[8], news[9], old[9]);
    
    logMsg("🎉 Патч в памяти применён!");
    notify("🎉 УСПЕХ!", gameMsg);
    return 0;
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        printf("\n═══════════════════════════════════════════════\n");
        printf("   HITBOX PATCHER v5.0 — In-Memory\n");
        printf("═══════════════════════════════════════════════\n\n");
        
        // Даём игре время загрузиться
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            patchInMemory();
        });
        
        printf("\n═══════════════════════════════════════════════\n");
        printf("📁 Лог: saves/hitbox_patch.log\n");
        printf("═══════════════════════════════════════════════\n\n");
    }
}

int main(void) { init(); while(1) sleep(1); return 0; }
