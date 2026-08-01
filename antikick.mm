// antikick.mm - WORKING VERSION

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static UIBackgroundTaskIdentifier gBgTask = UIBackgroundTaskInvalid;
static bool gInBackground = false;
static bool gKeepAlive = true;
static int gTaskCounter = 0;
static NSTimer *gTimer = nil;

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
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        
        NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
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

static void register_task(void) {
    @autoreleasepool {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        
        UIApplication *app = [UIApplication sharedApplication];
        
        gTaskCounter++;
        
        if (gBgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:gBgTask];
            gBgTask = UIBackgroundTaskInvalid;
        }
        
        gBgTask = [app beginBackgroundTaskWithName:@"KeepAlive" 
                                 expirationHandler:^{
            write_log(@"[!] Task expired, re-registering...");
            if (gBgTask != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:gBgTask];
                gBgTask = UIBackgroundTaskInvalid;
            }
            if (gInBackground) {
                register_task();
            }
        }];
        
        write_log(@"[✓] BG Task #%d: %lu", gTaskCounter, (unsigned long)gBgTask);
        
        #pragma clang diagnostic pop
    }
}

static void keep_alive_tick(NSTimer *timer) {
    @autoreleasepool {
        static int tick = 0;
        tick++;
        
        // Log every 10 seconds
        if (tick % 10 == 0) {
            write_log(@"[♥] Keep-alive tick #%d", tick);
        }
        
        // If in background and no task - re-register
        if (gInBackground && gBgTask == UIBackgroundTaskInvalid) {
            write_log(@"[!] No task in background! Re-registering...");
            register_task();
        }
        
        // Check time remaining if in background
        if (gInBackground) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            double remaining = [[UIApplication sharedApplication] backgroundTimeRemaining];
            #pragma clang diagnostic pop
            
            if (remaining < 30.0 && remaining > 0) {
                write_log(@"[⚠] Low time: %.1f sec, refreshing...", remaining);
                register_task();
            }
        }
    }
}

static void init(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     ANTI-KICK MODULE                                     ║");
    write_log(@"║     Keeps app alive in background                       ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    #pragma clang diagnostic pop
    
    register_task();
    
    // Timer every 1 second
    gTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:[NSObject new]
                                            selector:@selector(description)
                                            userInfo:nil
                                             repeats:YES];
    // Add timer to run loop
    [[NSRunLoop currentRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
    
    // Keep timer alive
    [[NSRunLoop currentRunLoop] run];
    
    // Notifications
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"");
        write_log(@"[📱] Background mode");
        gInBackground = true;
        register_task();
        write_log(@"");
    }];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"");
        write_log(@"[📱] Foreground mode");
        gInBackground = false;
        if (gBgTask != UIBackgroundTaskInvalid) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] endBackgroundTask:gBgTask];
            #pragma clang diagnostic pop
            gBgTask = UIBackgroundTaskInvalid;
            write_log(@"[✓] Task ended");
        }
        write_log(@"");
    }];
    
    write_log(@"[✓] Anti-kick initialized");
    write_log(@"[✓] Timer running every 1 second");
    write_log(@"[✓] App will stay alive in background");
    write_log(@"");
}

__attribute__((constructor))
static void inject(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            init();
        } @catch (NSException *e) {
            write_log(@"[✖] Error: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
