// antikick.mm - Lightweight Anti-Suspend

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>

static bool gRunning = true;

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

// Только фоновые задачи, без бесконечного цикла
static void register_background_task(void) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    
    UIApplication *app = [UIApplication sharedApplication];
    
    UIBackgroundTaskIdentifier bgTask = [app beginBackgroundTaskWithName:@"KeepAlive" 
                                                       expirationHandler:^{
        // Если истекает - просто перерегистрируем
        [app endBackgroundTask:bgTask];
        register_background_task();
    }];
    
    #pragma clang diagnostic pop
    
    write_log(@"Background task registered: %lu", (unsigned long)bgTask);
}

// Лёгкий таймер вместо бесконечного цикла
static void keep_alive_timer(void) {
    // Просто тикает каждые 5 секунд
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (gRunning) {
            write_log(@"Keep-alive tick");
            register_background_task();
            keep_alive_timer();
        }
    });
}

static void init_anti_kick(void) {
    write_log(@"");
    write_log(@"ANTI-KICK LITE INITIALIZED");
    
    // Отключаем режим ожидания (безопасно)
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    #pragma clang diagnostic pop
    
    // Регистрируем фоновую задачу
    register_background_task();
    
    // Запускаем таймер
    keep_alive_timer();
    
    // Слушаем уведомления
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"Background - refreshing task");
        register_background_task();
    }];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"Foreground - all good");
    }];
    
    write_log(@"ANTI-KICK ACTIVE (lite mode)");
    write_log(@"");
}

__attribute__((constructor))
static void inject(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            init_anti_kick();
        } @catch (NSException *e) {
            write_log(@"Anti-kick error: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
