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

static NSString* get_downloads_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = [paths firstObject];
    NSString *downloads = [doc stringByAppendingPathComponent:@"Downloads"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:downloads]) {
        [fm createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return downloads;
}

static void log_to_file(const char *msg) {
    NSString *logPath = [get_downloads_path() stringByAppendingPathComponent:@"hitbox_patch.log"];
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

static void show_alert(const char *title, const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithUTF8String:title]
                                                                       message:[NSString stringWithUTF8String:msg]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *root = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) {
                        if (w.rootViewController) { root = w.rootViewController; break; }
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

static void* find_hitbox(const char *libname, long *offset) {
    uint32_t count = _dyld_image_count();
    unsigned char sig[4] = {0x9A,0x99,0x19,0x3E};
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, libname)) {
            void *base = (void*)_dyld_get_image_vmaddr_slide(i);
            struct mach_header_64 *header = (struct mach_header_64*)_dyld_get_image_header(i);
            if (!header) continue;
            uintptr_t size = 0;
            struct load_command *cmd = (struct load_command*)((uintptr_t)header + sizeof(struct mach_header_64));
            for (uint32_t j = 0; j < header->ncmds; j++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    struct segment_command_64 *seg = (struct segment_command_64*)cmd;
                    if (strcmp(seg->segname, "__DATA") == 0 || strcmp(seg->segname, "__TEXT") == 0)
                        size += seg->vmsize;
                }
                cmd = (struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
            }
            unsigned char *start = (unsigned char*)base;
            for (uintptr_t i = 0; i < size - 4; i += 4) {
                if (memcmp(start + i, sig, 4) == 0) {
                    HitboxValues *hb = (HitboxValues*)(start + i);
                    float vals[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
                    int ok = 1;
                    for (int j = 0; j < 10; j++) if (fabs(vals[j] - orig[j]) > 0.001f) { ok = 0; break; }
                    if (ok) {
                        *offset = i;
                        return start + i;
                    }
                }
            }
        }
    }
    return NULL;
}

__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @autoreleasepool {
            log_to_file("=== Запуск патча хитбоксов ===");
            show_alert("🔄 Применяем патч", "Поиск хитбоксов в памяти...");
            
            long offset = 0;
            void *addr = find_hitbox("blackrussia-client", &offset);
            if (!addr) addr = find_hitbox("BrBase", &offset);
            
            if (!addr) {
                log_to_file("❌ Хитбоксы не найдены");
                show_alert("❌ Ошибка", "Хитбоксы не найдены в памяти");
                return;
            }
            
            HitboxValues *hb = (HitboxValues*)addr;
            float old[10] = {hb->head, hb->torso_1, hb->torso_2, hb->legs_1, hb->legs_2, hb->arms_1, hb->arms_2, hb->chest, hb->stomach, hb->pelvis};
            
            char log_buf[256];
            snprintf(log_buf, sizeof(log_buf), "Найдено по адресу: %p", addr);
            log_to_file(log_buf);
            
            for (int i = 0; i < 10; i++) {
                snprintf(log_buf, sizeof(log_buf), "  %s: %.3f", names[i], old[i]);
                log_to_file(log_buf);
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
            
            log_to_file("✅ Патч применён!");
            
            char alert_msg[1024];
            snprintf(alert_msg, sizeof(alert_msg),
                     "✅ Хитбоксы заменены!\n\n"
                     "Адрес: %p\n\n"
                     "HEAD: %.3f → %.3f\n"
                     "TORSO_1: %.3f → %.3f\n"
                     "TORSO_2: %.3f → %.3f\n"
                     "LEGS_1: %.3f → %.3f\n"
                     "LEGS_2: %.3f → %.3f\n"
                     "ARMS_1: %.3f → %.3f\n"
                     "ARMS_2: %.3f → %.3f\n"
                     "CHEST: %.3f → %.3f\n"
                     "STOMACH: %.3f → %.3f\n"
                     "PELVIS: %.3f → %.3f\n\n"
                     "📁 Лог: На iPhone → Загрузки → hitbox_patch.log",
                     addr,
                     old[0], news[0],
                     old[1], news[1],
                     old[2], news[2],
                     old[3], news[3],
                     old[4], news[4],
                     old[5], news[5],
                     old[6], news[6],
                     old[7], news[7],
                     old[8], news[8],
                     old[9], news[9]);
            
            show_alert("🎯 Успех!", alert_msg);
        }
    });
}

int main() {
    @autoreleasepool {
        init();
        while(1) sleep(1);
    }
    return 0;
}
