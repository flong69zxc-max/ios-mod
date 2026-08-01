// main.m

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>

typedef struct {
    const unsigned char original[4];
    const unsigned char patched[4];
    const char *name;
} HitboxPatch;

HitboxPatch patches[] = {
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}, "HEAD"},
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}, "TORSO_1"},
    {{0x00, 0x00, 0x80, 0x3E}, {0x00, 0x00, 0xC0, 0x3E}, "TORSO_2"},
    {{0x00, 0x00, 0x80, 0x3E}, {0x00, 0x00, 0xC0, 0x3E}, "MID"},
    {{0x48, 0xE1, 0x24, 0x3E}, {0x48, 0xE1, 0x74, 0x3E}, "LEFTARM"},
    {{0x48, 0xE1, 0x24, 0x3E}, {0x48, 0xE1, 0x74, 0x3E}, "RIGHTARM"},
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}, "LEFTLEG_1"},
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}, "RIGHTLEG_1"},
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}, "LEFTLEG_2"},
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}, "RIGHTLEG_2"}
};

#define NUM_PATCHES (sizeof(patches) / sizeof(patches[0]))
#define STEP_SIZE 0x20

static UIWindow *alertWindow = nil;

void showNotification(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        alertWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        alertWindow.rootViewController = [[UIViewController alloc] init];
        alertWindow.windowLevel = UIWindowLevelAlert + 1;
        alertWindow.hidden = NO;
        
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:title 
            message:message 
            preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *okAction = [UIAlertAction 
            actionWithTitle:@"OK" 
            style:UIAlertActionStyleDefault 
            handler:^(UIAlertAction *action) {
                alertWindow.hidden = YES;
                alertWindow = nil;
            }];
        
        [alert addAction:okAction];
        [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

NSString* getTargetPath() {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSArray *possiblePaths = @[
        @"Frameworks/blackrussia-client.framework/blackrussia-client",
        @"blackrussia-client.framework/blackrussia-client",
        @"blackrussia-client"
    ];
    
    for (NSString *relativePath in possiblePaths) {
        NSString *fullPath = [bundlePath stringByAppendingPathComponent:relativePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
            return fullPath;
        }
    }
    
    return nil;
}

BOOL isValidArchitecture(void *data) {
    uint32_t magic = *(uint32_t *)data;
    
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header *fat = (struct fat_header *)data;
        struct fat_arch *arch = (struct fat_arch *)(fat + 1);
        
        for (uint32_t i = 0; i < OSSwapBigToHostInt32(fat->nfat_arch); i++) {
            if (OSSwapBigToHostInt32(arch[i].cputype) == CPU_TYPE_ARM64) {
                return YES;
            }
        }
        return NO;
    }
    
    if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        struct mach_header_64 *header = (struct mach_header_64 *)data;
        return header->cputype == CPU_TYPE_ARM64;
    }
    
    return NO;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        showNotification(@"Hitbox Patcher", @"🔍 Поиск хитбоксов...");
        
        NSString *targetPath = getTargetPath();
        if (!targetPath) {
            showNotification(@"Ошибка", @"Файл blackrussia-client не найден в приложении");
            return 1;
        }
        
        const char *pathCString = [targetPath UTF8String];
        
        if (access(pathCString, F_OK) != 0) {
            showNotification(@"Ошибка", [NSString stringWithFormat:@"Файл не найден:\n%@", targetPath]);
            return 1;
        }
        
        int fd = open(pathCString, O_RDWR);
        if (fd == -1) {
            showNotification(@"Ошибка", @"Нет прав на запись в файл");
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
        
        if (!isValidArchitecture(mapped)) {
            showNotification(@"Ошибка", @"Файл не содержит ARM64 код");
            munmap(mapped, fileSize);
            close(fd);
            return 1;
        }
        
        unsigned char *data = (unsigned char *)mapped;
        NSMutableArray *foundOffsets = [NSMutableArray array];
        NSMutableString *logMessage = [NSMutableString string];
        BOOL allFound = YES;
        
        for (int i = 0; i < NUM_PATCHES; i++) {
            const unsigned char *pattern = patches[i].original;
            size_t searchLimit = fileSize - 4;
            BOOL found = NO;
            
            for (size_t offset = 0; offset < searchLimit; offset++) {
                if (memcmp(data + offset, pattern, 4) == 0) {
                    if (i > 0) {
                        NSNumber *prevOffset = foundOffsets[i - 1];
                        size_t expectedOffset = [prevOffset unsignedLongValue] + STEP_SIZE;
                        if (offset != expectedOffset) {
                            continue;
                        }
                    }
                    
                    [foundOffsets addObject:@(offset)];
                    [logMessage appendFormat:@"%s: 0x%08lx\n", patches[i].name, offset];
                    found = YES;
                    break;
                }
            }
            
            if (!found) {
                allFound = NO;
                showNotification(@"Ошибка", [NSString stringWithFormat:@"Хитбокс %s не найден", patches[i].name]);
                break;
            }
        }
        
        if (!allFound) {
            munmap(mapped, fileSize);
            close(fd);
            return 1;
        }
        
        [logMessage insertString:@"✅ Найдены все хитбоксы:\n" atIndex:0];
        showNotification(@"Хитбоксы найдены!", logMessage);
        
        NSString *backupPath = [targetPath stringByAppendingString:@".backup"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
            NSData *backupData = [NSData dataWithBytes:mapped length:fileSize];
            [backupData writeToFile:backupPath atomically:YES];
        }
        
        for (int i = 0; i < NUM_PATCHES; i++) {
            size_t offset = [foundOffsets[i] unsignedLongValue];
            const unsigned char *patch = patches[i].patched;
            memcpy(data + offset, patch, 4);
        }
        
        if (msync(mapped, fileSize, MS_SYNC) != 0) {
            showNotification(@"Предупреждение", @"Изменения могут не сохраниться");
        }
        
        munmap(mapped, fileSize);
        close(fd);
        
        showNotification(@"✅ Готово!", 
            [NSString stringWithFormat:@"Все 10 хитбоксов запатчены ×1.5\nБэкап: %@", backupPath]);
        
        sleep(2);
    }
    return 0;
}
