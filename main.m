#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>

typedef struct {
    uint32_t original[4];
    uint32_t replacement[4];
} HitboxPair;

static HitboxPair g_hitboxes[] = {
    {{0x3E,0x19,0x99,0x9A}, {0x3E,0x66,0x66,0x66}},
    {{0x3E,0x4C,0xCC,0xCD}, {0x3E,0x99,0x99,0x9A}},
    {{0x3E,0x80,0x00,0x00}, {0x3E,0xC0,0x00,0x00}},
    {{0x3E,0x80,0x00,0x00}, {0x3E,0xC0,0x00,0x00}},
    {{0x3E,0x24,0xE1,0x48}, {0x3E,0x74,0xE1,0x48}},
    {{0x3E,0x24,0xE1,0x48}, {0x3E,0x74,0xE1,0x48}},
    {{0x3E,0x4C,0xCC,0xCD}, {0x3E,0x99,0x99,0x9A}},
    {{0x3E,0x4C,0xCC,0xCD}, {0x3E,0x99,0x99,0x9A}},
    {{0x3E,0x19,0x99,0x9A}, {0x3E,0x66,0x66,0x66}},
    {{0x3E,0x19,0x99,0x9A}, {0x3E,0x66,0x66,0x66}}
};

#define HITBOX_COUNT (sizeof(g_hitboxes) / sizeof(HitboxPair))

static void patchHitboxes(void);

static uintptr_t getFrameworkRange(uintptr_t *start, uintptr_t *end) {
    Dl_info info;
    if (dladdr((const void *)patchHitboxes, &info) == 0) return 0;
    
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (!header) return 0;
    
    uintptr_t base = (uintptr_t)header;
    struct load_command *cmd = (struct load_command *)(base + sizeof(struct mach_header_64));
    
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__DATA") == 0 || strcmp(seg->segname, "__DATA_CONST") == 0) {
                *start = base + seg->vmaddr;
                *end = *start + seg->vmsize;
                return 1;
            }
        }
        cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }
    return 0;
}

static uintptr_t findPattern(uint32_t pattern[4]) {
    uintptr_t start = 0, end = 0;
    
    if (!getFrameworkRange(&start, &end)) return 0;
    if (!start || !end) return 0;
    
    for (uintptr_t addr = start; addr < end - 16; addr += 4) {
        uint32_t *ptr = (uint32_t *)addr;
        if (ptr[0] == pattern[0] && ptr[1] == pattern[1] && 
            ptr[2] == pattern[2] && ptr[3] == pattern[3]) {
            return addr;
        }
    }
    return 0;
}

static UIViewController *getTopViewController(void) {
    UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] allObjects].firstObject;
    UIWindow *keyWindow = scene.windows.firstObject;
    if (!keyWindow) {
        for (UIWindowScene *s in [[UIApplication sharedApplication] connectedScenes]) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = s.windows.firstObject;
                break;
            }
        }
    }
    return keyWindow.rootViewController;
}

static void showNotification(int found, uintptr_t offsets[10]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableString *msg = [NSMutableString string];
        
        if (found == HITBOX_COUNT) {
            [msg appendString:@"✅ Все хитбоксы записаны\n\n"];
        } else if (found > 0) {
            [msg appendFormat:@"⚠️ Найдено %d из %lu\n\n", found, (unsigned long)HITBOX_COUNT];
        } else {
            [msg appendString:@"❌ Хитбоксы не найдены\n"];
        }
        
        for (int i = 0; i < found; i++) {
            [msg appendFormat:@"[%d] 0x%llX\n", i, (unsigned long long)offsets[i]];
        }
        
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:@"🎯 BlackRussia Hitbox"
            message:msg
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        
        UIViewController *topVC = getTopViewController();
        if (topVC) {
            [topVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

__attribute__((constructor))
static void patchHitboxes() {
    uintptr_t offsets[10] = {0};
    int found = 0;
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        uintptr_t addr = findPattern(g_hitboxes[i].original);
        if (addr) {
            offsets[found++] = addr;
            uint32_t *ptr = (uint32_t *)addr;
            for (int j = 0; j < 4; j++) {
                ptr[j] = g_hitboxes[i].replacement[j];
            }
        }
    }
    
    showNotification(found, offsets);
}
