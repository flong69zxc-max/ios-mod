#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

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
static const char *names[10] = {"HEAD","TORSO_1","TORSO_2","LEGS_1","LEGS_2","ARMS_1","ARMS_2","CHEST","STOMACH","PELVIS"};

static void log_msg(const char *msg) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char ts[20];
    strftime(ts, sizeof(ts), "%H:%M:%S", tm);
    
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *saves = [doc stringByAppendingPathComponent:@"saves"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:saves]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *logPath = [saves stringByAppendingPathComponent:@"hitbox_patch.log"];
    FILE *f = fopen([logPath UTF8String], "a");
    if (f) { fprintf(f, "[%s] %s\n", ts, msg); fclose(f); }
}

static void show_notification(const char *title, const char *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithUTF8String:title]
                                                                       message:[NSString stringWithUTF8String:message]
                                                                preferredStyle:UIAlertControllerStyleAlert];
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
                if (w.rootViewController) {
                    root = w.rootViewController;
                    break;
                }
            }
        }
        if (root) {
            [root presentViewController:alert animated:YES completion:nil];
        }
    });
}

static void* find_in_memory(const char *filename, const unsigned char *sig, size_t sig_len, long *offset) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, filename)) {
            void *base = (void*)_dyld_get_image_vmaddr_slide(i);
            struct mach_header_64 *header = (struct mach_header_64*)_dyld_get_image_header(i);
            if (!header) continue;
            
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
            
            unsigned char *start = (unsigned char*)base;
            for (uintptr_t i = 0; i < size - sig_len; i += 4) {
                if (memcmp(start + i, sig, sig_len) == 0) {
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

__attribute__((constructor)) static void init(void) {
    // Даём игре загрузиться
    sleep(2);
    
    show_notification("🔄 Применяем патч", "Поиск хитбоксов в памяти...");
    log_msg("🚀 Запуск патча в памяти");
    
    unsigned char sig[4] = {0x9A, 0x99, 0x19, 0x3E};
    long offset = 0;
    void *addr = find_in_memory("blackrussia-client", sig, 4, &offset);
    if (!addr) {
        addr = find_in_memory("BrBase", sig, 4, &offset);
    }
    
    if (!addr) {
        log_msg("❌ Хитбоксы не найдены в памяти");
        show_notification("❌ Ошибка", "Хитбоксы не найдены в памяти");
        return;
    }
    
    HitboxValues *hb = (HitboxValues*)addr;
    float old[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
    
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "✅ Найдено по адресу: %p (offset: 0x%lX)", addr, offset);
    log_msg(tmp);
    
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f", names[i], old[i]);
        log_msg(tmp);
    }
    
    // Патчим в памяти
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
    
    log_msg("📊 Изменения:");
    for (int i = 0; i < 10; i++) {
        snprintf(tmp, sizeof(tmp), "  %s: %.3f → %.3f", names[i], old[i], news[i]);
        log_msg(tmp);
    }
    
    log_msg("🎉 Патч в памяти применён успешно!");
    
    // Формируем сообщение для уведомления
    char msg[1024];
    snprintf(msg, sizeof(msg),
             "✅ Хитбоксы успешно установлены!\n\n"
             "HEAD: %.3f (было %.3f)\n"
             "TORSO_1: %.3f (было %.3f)\n"
             "TORSO_2: %.3f (было %.3f)\n"
             "LEGS_1: %.3f (было %.3f)\n"
             "LEGS_2: %.3f (было %.3f)\n"
             "ARMS_1: %.3f (было %.3f)\n"
             "ARMS_2: %.3f (было %.3f)\n"
             "CHEST: %.3f (было %.3f)\n"
             "STOMACH: %.3f (было %.3f)\n"
             "PELVIS: %.3f (было %.3f)",
             news[0], old[0],
             news[1], old[1],
             news[2], old[2],
             news[3], old[3],
             news[4], old[4],
             news[5], old[5],
             news[6], old[6],
             news[7], old[7],
             news[8], old[8],
             news[9], old[9]);
    
    show_notification("🎉 Успех!", msg);
}

int main(void) { return 0; }
