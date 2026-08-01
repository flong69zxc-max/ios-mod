// antikick.mm - Fixed version

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>

static bool gRunning = true;
static UIBackgroundTaskIdentifier gBgTask = UIBackgroundTaskInvalid;

static void write_log(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths firstObject];
        NSString *savesPath = [documentsPath stringByAppendingPathComponent:@"saves"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:savesPath]) {
            [fileManager createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"AntiKick.log"];
        NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
        
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } else {
            [logEntry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        NSLog(@"%@", logEntry);
    }
}

static void register_background_task(void) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    
    UIApplication *app = [UIApplication sharedApplication];
    
    // Закрываем старую задачу если есть
    if (gBgTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:gBgTask];
        gBgTask = UIBackgroundTaskInvalid;
    }
    
    // Регистрируем новую
    gBgTask = [app beginBackgroundTaskWithName:@"KeepAlive" 
                             expirationHandler:^{
        // Если истекает - закрываем и перерегистрируем
        if (gBgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:gBgTask];
            gBgTask = UIBackgroundTaskInvalid;
        }
        // Перерегистрируем через 1 секунду
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            register_background_task();
        });
    }];
    
    #pragma clang diagnostic pop
    
    write_log(@"Background task: %lu", (unsigned long)gBgTask);
}

// Только регистрируем задачу, без бесконечных таймеров
static void init_anti_kick(void) {
    write_log(@"");
    write_log(@"ANTI-KICK INITIALIZED");
    
    // Отключаем режим ожидания
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    #pragma clang diagnostic pop
    
    // Регистрируем одну задачу
    register_background_task();
    
    // Слушаем уведомления
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"Background - refresh");
        register_background_task();
    }];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"Foreground");
        // Закрываем фоновую задачу при возврате
        if (gBgTask != UIBackgroundTaskInvalid) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] endBackgroundTask:gBgTask];
            #pragma clang diagnostic pop
            gBgTask = UIBackgroundTaskInvalid;
        }
    }];
    
    write_log(@"ANTI-KICK ACTIVE");
    write_log(@"");
}

__attribute__((constructor))
static void inject(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            init_anti_kick();
        } @catch (NSException *e) {
            write_log(@"Error: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
