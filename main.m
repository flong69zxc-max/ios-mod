// main.m
// Инструмент для патчинга хитбоксов в blackrussia-client
// ВНИМАНИЕ: Требует джейлбрейка или TrollStore для работы

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <sys/utsname.h>
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
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}, "RIGHT sizeofLE(G_2"}
};

#define NUM_PATCHES (sizeof(patches) /patches[0]))
#define STEP_SIZE 0x20

static UIWindow *alertWindow = nil;
static uint32_t arm64_offset = 0;
static size_t arm64_size = 0;

void showNotification(NSString *title, NSString *message, BOOL waitForOK) {
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
                if (waitForOK) {
                    CFRunLoopStop(CFRunLoopGetMain());
                }
            }];
        
        [alert addAction:okAction];
        [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
    
    if (waitForOK) {
        CFRunLoopRun();
    }
}

BOOL isJailbroken() {
    #if TARGET_IPHONE_SIMULATOR
        return NO;
    #else
        NSArray *paths = @[
            @"/Applications/Cydia.app",
            @"/Library/MobileSubstrate/MobileSubstrate.dylib",
            @"/bin/bash",
            @"/usr/sbin/sshd",
            @"/etc/apt"
        ];
        
        for (NSString *path in paths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return YES;
            }
        }
        
        // Проверка через system
        FILE *file = fopen("/bin/sh", "r");
        if (file) {
            fclose(file);
            return YES;
        }
        
        return NO;
    #endif
}

NSString* getTargetPath() {
    // Сначала проверяем стандартный путь
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
    
    // Альтернативный поиск через /var/mobile
    NSString *altPath = @"/var/mobile/Containers/Bundle/Application";
    NSArray *appDirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:altPath error:nil];
    
    for (NSString *appDir in appDirs) {
        NSString *appPath = [altPath stringByAppendingPathComponent:appDir];
        NSArray *bundleDirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appPath error:nil];
        
        for (NSString *bundleDir in bundleDirs) {
            if ([bundleDir hasSuffix:@".app"]) {
                NSString *fullAppPath = [appPath stringByAppendingPathComponent:bundleDir];
                NSString *frameworkPath = [fullAppPath stringByAppendingPathComponent:@"Frameworks/blackrussia-client.framework/blackrussia-client"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:frameworkPath]) {
                    return frameworkPath;
                }
            }
        }
    }
    
    return nil;
}

BOOL isValidArchitecture(void *data, size_t fileSize) {
    uint32_t magic = *(uint32_t *)data;
    
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header *fat = (struct fat_header *)data;
        struct fat_arch *arch = (struct fat_arch *)(fat + 1);
        
        for (uint32_t i = 0; i < OSSwapBigToHostInt32(fat->nfat_arch); i++) {
            cpu_type_t cputype = OSSwapBigToHostInt32(arch[i].cputype);
            if (cputype == CPU_TYPE_ARM64 || cputype == CPU_TYPE_ARM64_32) {
                arm64_offset = OSSwapBigToHostInt32(arch[i].offset);
                arm64_size = OSSwapBigToHostInt32(arch[i].size);
                return YES;
            }
        }
        return NO;
    }
    
    if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        arm64_offset = 0;
        arm64_size = fileSize;
        cpu_type_t cputype = ((struct mach_header_64 *)data)->cputype;
        return (cputype == CPU_TYPE_ARM64 || cputype == CPU_TYPE_ARM64_32);
    }
    
    return NO;
}

BOOL patchFile(NSString *targetPath) {
    const char *pathCString = [targetPath UTF8String];
    
    // Проверка прав доступа
    if (access(pathCString, W_OK) != 0) {
        showNotification(@"Ошибка", @"Нет прав на запись. Запустите с правами root", YES);
        return NO;
    }
    
    int fd = open(pathCString, O_RDWR);
    if (fd == -1) {
        showNotification(@"Ошибка", [NSString stringWithFormat:@"Не удалось открыть файл:\n%m"], YES);
        return NO;
    }
    
    struct stat st;
    if (fstat(fd, &st) != 0) {
        showNotification(@"Ошибка", @"Не удалось получить размер файла", YES);
        close(fd);
        return NO;
    }
    size_t fileSize = st.st_size;
    
    // Копируем файл во временную директорию
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"patched_binary"];
    NSData *fileData = [NSData dataWithContentsOfFile:targetPath];
    if (!fileData) {
        showNotification(@"Ошибка", @"Не удалось прочитать файл", YES);
        close(fd);
        return NO;
    }
    
    if (![fileData writeToFile:tempPath atomically:YES]) {
        showNotification(@"Ошибка", @"Не удалось создать временный файл", YES);
        close(fd);
        return NO;
    }
    
    // Работаем с временным файлом
    int tempFd = open([tempPath UTF8String], O_RDWR);
    if (tempFd == -1) {
        showNotification(@"Ошибка", @"Не удалось открыть временный файл", YES);
        close(fd);
        return NO;
    }
    
    void *mapped = mmap(NULL, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, tempFd, 0);
    if (mapped == MAP_FAILED) {
        showNotification(@"Ошибка", @"Не удалось отобразить файл в память", YES);
        close(tempFd);
        close(fd);
        return NO;
    }
    
    if (!isValidArchitecture(mapped, fileSize)) {
        showNotification(@"Ошибка", @"Файл не содержит ARM64 код", YES);
        munmap(mapped, fileSize);
        close(tempFd);
        close(fd);
        return NO;
    }
    
    unsigned char *data = (unsigned char *)mapped + arm64_offset;
    size_t dataSize = arm64_size > 0 ? arm64_size : fileSize - arm64_offset;
    
    NSMutableArray *foundOffsets = [NSMutableArray array];
    NSMutableString *logMessage = [NSMutableString string];
    BOOL allFound = YES;
    
    for (int i = 0; i < NUM_PATCHES; i++) {
        const unsigned char *pattern = patches[i].original;
        size_t searchLimit = dataSize - 4;
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
            showNotification(@"Ошибка", [NSString stringWithFormat:@"Хитбокс %s не найден", patches[i].name], YES);
            break;
        }
    }
    
    if (!allFound) {
        munmap(mapped, fileSize);
        close(tempFd);
        close(fd);
        return NO;
    }
    
    [logMessage insertString:@"✅ Найдены все хитбоксы:\n" atIndex:0];
    showNotification(@"Хитбоксы найдены!", logMessage, YES);
    
    // Создаем бэкап
    NSString *backupPath = [targetPath stringByAppendingString:@".backup"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
        NSData *backupData = [NSData dataWithContentsOfFile:targetPath];
        [backupData writeToFile:backupPath atomically:YES];
        showNotification(@"📦 Бэкап", [NSString stringWithFormat:@"Создан бэкап:\n%@", backupPath], YES);
    }
    
    // Применяем патчи
    for (int i = 0; i < NUM_PATCHES; i++) {
        size_t offset = [foundOffsets[i] unsignedLongValue];
        const unsigned char *patch = patches[i].patched;
        memcpy(data + offset, patch, 4);
        
        if (memcmp(data + offset, patch, 4) != 0) {
            showNotification(@"Ошибка", [NSString stringWithFormat:@"Не удалось применить патч %s", patches[i].name], YES);
            munmap(mapped, fileSize);
            close(tempFd);
            close(fd);
            return NO;
        }
    }
    
    if (msync(mapped, fileSize, MS_SYNC) != 0) {
        showNotification(@"Предупреждение", @"Изменения могут не сохраниться", YES);
    }
    
    munmap(mapped, fileSize);
    close(tempFd);
    
    // Копируем запатченный файл обратно
    NSData *patchedData = [NSData dataWithContentsOfFile:tempPath];
    if (![patchedData writeToFile:targetPath atomically:YES]) {
        showNotification(@"Ошибка", @"Не удалось записать патчи в целевой файл", YES);
        close(fd);
        return NO;
    }
    
    close(fd);
    
    // Удаляем временный файл
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    
    return YES;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Проверка прав
        if (!isJailbroken() && getuid() != 0) {
            showNotification(@"⚠️ Требуется джейлбрейк", 
                @"Инструмент требует:\n• Джейлбрейк\n• Запуск с правами root\n• TrollStore\n\nИли используйте патчинг IPA на компьютере", 
                YES);
            return 1;
        }
        
        showNotification(@"Hitbox Patcher", @"🔍 Поиск blackrussia-client...", YES);
        
        NSString *targetPath = getTargetPath();
        if (!targetPath) {
            showNotification(@"Ошибка", 
                @"Файл blackrussia-client не найден\n\nУбедитесь, что игра установлена", 
                YES);
            return 1;
        }
        
        showNotification(@"📁 Найден файл", 
            [NSString stringWithFormat:@"%@", targetPath], 
            YES);
        
        // Проверка права на запись
        if (access([targetPath UTF8String], W_OK) != 0) {
            showNotification(@"⚠️ Нет прав на запись", 
                @"Попытка получить права root...\n\nЗапустите инструмент через sudo", 
                YES);
            
            // Попытка получить права
            if (getuid() != 0) {
                showNotification(@"❌ Ошибка", 
                    @"Нет прав root.\n\nЗапустите:\nsu\n./hitbox_patcher", 
                    YES);
                return 1;
            }
        }
        
        // Проверка на ARM64e
        struct utsname systemInfo;
        uname(&systemInfo);
        NSString *machine = [NSString stringWithUTF8String:systemInfo.machine];
        if ([machine hasPrefix:@"iPhone12"] || [machine hasPrefix:@"iPhone13"] || [machine hasPrefix:@"iPad8"]) {
            showNotification(@"ℹ️ ARM64e устройство", 
                @"Обнаружено устройство с ARM64e (A12+).\nПатчинг должен работать корректно.", 
                YES);
        }
        
        if (patchFile(targetPath)) {
            showNotification(@"✅ Готово!", 
                [NSString stringWithFormat:@"Все 10 хитбоксов запатчены ×1.5\n\n📦 Бэкап сохранен:\n%@.backup\n\n⚠️ Перезапустите игру для применения изменений", 
                    targetPath], 
                YES);
        } else {
            showNotification(@"❌ Ошибка", 
                @"Не удалось применить патчи\n\nБэкап сохранен, вы можете восстановить его", 
                YES);
        }
    }
    return 0;
}
