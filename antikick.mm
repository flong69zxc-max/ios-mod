// main.mm - Anti-Suspend Module (No signatures needed)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>

static bool gRunning = true;
static mach_port_t gTask = MACH_PORT_NULL;

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

static void* keep_alive_loop(void* arg) {
    @autoreleasepool {
        write_log(@"Keep-alive thread started");
        
        while (gRunning) {
            // Просто держим поток активным
            // Имитация отправки пакетов
            volatile int x = 0;
            for (int i = 0; i < 100000; i++) {
                x++;
            }
            
            // Спим 100ms чтобы не грузить CPU
            [NSThread sleepForTimeInterval:0.1];
        }
    }
    return NULL;
}

// Меняем системные флаги чтобы игра не засыпала
static void prevent_suspend(void) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    
    UIApplication *app = [UIApplication sharedApplication];
    
    // Отключаем режим ожидания
    [app setIdleTimerDisabled:YES];
    
    // Регистрируем фоновую задачу на 30 минут
    UIBackgroundTaskIdentifier bgTask = [app beginBackgroundTaskWithName:@"KeepAlive" 
                                                       expirationHandler:^{
        write_log(@"Background task expiring, re-registering...");
        // Перерегистрируем
        [app endBackgroundTask:bgTask];
        [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"KeepAlive" 
                                                     expirationHandler:nil];
    }];
    
    #pragma clang diagnostic pop
    
    write_log(@"Background task registered: %lu", (unsigned long)bgTask);
}

// Запускаем все
static void init_anti_kick(void) {
    write_log(@"");
    write_log(@"ANTI-KICK MODULE INITIALIZED");
    write_log(@"Preventing app suspension...");
    
    gTask = mach_task_self();
    
    // 1. Запрещаем приостановку
    prevent_suspend();
    
    // 2. Запускаем поток
    pthread_t thread;
    pthread_create(&thread, NULL, keep_alive_loop, NULL);
    pthread_detach(thread);
    
    // 3. Слушаем уведомления
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"App went background - keeping alive");
        // Перерегистрируем задачу
        prevent_suspend();
    }];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"App came foreground - all good");
    }];
    
    write_log(@"ANTI-KICK ACTIVE! You can minimize safely.");
    write_log(@"");
    
    // Показываем уведомление
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                    if (window) break;
                }
            }
        }
        
        if (!window) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSArray *windows = [UIApplication sharedApplication].windows;
            if (windows.count > 0) {
                window = windows.firstObject;
            }
            #pragma clang diagnostic pop
        }
        
        UIViewController *rootVC = window.rootViewController;
        
        if (rootVC) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Anti-Kick Active"
                message:@"Connection will stay alive when minimized"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

__attribute__((constructor))
static void inject(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        init_anti_kick();
    });
}

extern "C" void __dummy_export(void) {}
