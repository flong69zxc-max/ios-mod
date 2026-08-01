// main.m

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/mman.h>
#import <sys/stat.h>

#define TARGET_PATH "/var/mobile/Containers/Bundle/Application/.../BlackRussia.app/Frameworks/blackrussia-client.framework/blackrussia-client"

typedef struct {
    const unsigned char original[4];
    const unsigned char patched[4];
} HitboxPatch;

HitboxPatch patches[] = {
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}},
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}},
    {{0x00, 0x00, 0x80, 0x3E}, {0x00, 0x00, 0xC0, 0x3E}},
    {{0x00, 0x00, 0x80, 0x3E}, {0x00, 0x00, 0xC0, 0x3E}},
    {{0x48, 0xE1, 0x24, 0x3E}, {0x48, 0xE1, 0x74, 0x3E}},
    {{0x48, 0xE1, 0x24, 0x3E}, {0x48, 0xE1, 0x74, 0x3E}},
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}},
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}},
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}},
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}}
};

#define NUM_PATCHES (sizeof(patches) / sizeof(patches[0]))
#define STEP_SIZE 0x20

void showNotification(NSString *title, NSString *message) {
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
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        showNotification(@"Hitbox Patcher", @"🔍 Поиск хитбоксов...");
        
        int fd = open(TARGET_PATH, O_RDWR);
        if (fd == -1) {
            showNotification(@"Ошибка", [NSString stringWithFormat:@"Не удалось открыть файл:\n%@", @TARGET_PATH]);
            return 1;
        }
        
        struct stat st;
        if (fstat(fd, &st) != 0) {
            showNotification(@"Ошибка", @"Не удалось получить размер файла");
            close(fd);
            return 1;
        }
        size_t fileSize = st.st_size;
        
        void *mapped = mmap(NULL, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapped == MAP_FAILED) {
            showNotification(@"Ошибка", @"Не удалось отобразить файл в память");
            close(fd);
            return 1;
        }
        
        unsigned char *data = (unsigned char *)mapped;
        BOOL foundAll = YES;
        NSMutableArray *foundOffsets = [NSMutableArray array];
        NSMutableString *offsetLog = [NSMutableString stringWithString:@"Найденные оффсеты:\n"];
        
        for (int i = 0; i < NUM_PATCHES; i++) {
            BOOL found = NO;
            const unsigned char *pattern = patches[i].original;
            size_t searchLimit = fileSize - 4;
            
            for (size_t offset = 0; offset < searchLimit; offset++) {
                if (memcmp(data + offset, pattern, 4) == 0) {
                    if (i > 0) {
                        NSNumber *prevOffset = foundOffsets[i - 1];
                        size_t expectedOffset = [prevOffset unsignedLongValue] + STEP_SIZE;
                        if (offset != expectedOffset) {
                            continue;
                        }
                    }
                    
                    found = YES;
                    [foundOffsets addObject:@(offset)];
                    [offsetLog appendFormat:@"Хитбокс %d: 0x%08lx\n", i, offset];
                    break;
                }
            }
            
            if (!found) {
                foundAll = NO;
                break;
            }
        }
        
        if (!foundAll || [foundOffsets count] != NUM_PATCHES) {
            showNotification(@"Ошибка", @"Не найдены все хитбоксы с правильным шагом 0x20");
            munmap(mapped, fileSize);
            close(fd);
            return 1;
        }
        
        showNotification(@"Хитбоксы найдены!", offsetLog);
        
        for (int i = 0; i < NUM_PATCHES; i++) {
            size_t offset = [foundOffsets[i] unsignedLongValue];
            const unsigned char *patch = patches[i].patched;
            memcpy(data + offset, patch, 4);
        }
        
        if (msync(mapped, fileSize, MS_SYNC) != 0) {
            showNotification(@"Предупреждение", @"Изменения могут не сохраниться на диск");
        }
        
        munmap(mapped, fileSize);
        close(fd);
        
        showNotification(@"✅ Готово!", 
            [NSString stringWithFormat:@"Все 10 хитбоксов успешно запатчены!\nОффсеты сохранены в логе."]);
    }
    return 0;
}
