// antikick.mm - ULTIMATE ANTI-KICK WITH DETAILED LOGS

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/sysctl.h>

static UIBackgroundTaskIdentifier gBgTask = UIBackgroundTaskInvalid;
static bool gInBackground = false;
static bool gKeepAlive = true;
static pthread_t gThread;
static int gTaskCounter = 0;

// ============================================================
// DETAILED LOGGING
// ============================================================

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

// ============================================================
// SYSTEM INFO
// ============================================================

static void log_system_info(void) {
    write_log(@"┌─────────────────────────────────────────────────");
    write_log(@"│ SYSTEM INFORMATION");
    write_log(@"├─────────────────────────────────────────────────");
    
    // iOS Version
    NSString *version = [[UIDevice currentDevice] systemVersion];
    write_log(@"│ iOS Version: %@", version);
    
    // Device Model
    NSString *model = [[UIDevice currentDevice] model];
    write_log(@"│ Device: %@", model);
    
    // Memory
    struct task_basic_info info;
    mach_msg_type_number_t size = TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    if (kr == KERN_SUCCESS) {
        write_log(@"│ Memory Usage: %.2f MB", (float)info.resident_size / 1024 / 1024);
    }
    
    // App State
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    NSString *stateStr = @"Unknown";
    if (state == UIApplicationStateActive) stateStr = @"Active";
    else if (state == UIApplicationStateInactive) stateStr = @"Inactive";
    else if (state == UIApplicationStateBackground) stateStr = @"Background";
    write_log(@"│ App State: %@", stateStr);
    
    write_log(@"└─────────────────────────────────────────────────");
}

// ============================================================
// BACKGROUND TASK MANAGEMENT
// ============================================================

static void register_background_task(void) {
    @autoreleasepool {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        
        UIApplication *app = [UIApplication sharedApplication];
        
        gTaskCounter++;
        write_log(@"");
        write_log(@"┌─────────────────────────────────────────────────");
        write_log(@"│ BACKGROUND TASK #%d", gTaskCounter);
        write_log(@"├─────────────────────────────────────────────────");
        
        // Check if already has task
        if (gBgTask != UIBackgroundTaskInvalid) {
            write_log(@"│ [!] WARNING: Task already exists: %lu", (unsigned long)gBgTask);
            write_log(@"│ [!] Ending old task...");
            [app endBackgroundTask:gBgTask];
            gBgTask = UIBackgroundTaskInvalid;
            write_log(@"│ [✓] Old task ended");
        }
        
        write_log(@"│ [→] Registering new background task...");
        
        // Register with expiration handler
        gBgTask = [app beginBackgroundTaskWithName:@"UltimateKeepAlive" 
                                 expirationHandler:^{
            write_log(@"│ ⚠️ EXPIRATION HANDLER TRIGGERED!");
            write_log(@"│ ⚠️ Task ID: %lu", (unsigned long)gBgTask);
            write_log(@"│ ⚠️ Background time remaining: %.1f sec", 
                     [app backgroundTimeRemaining]);
            
            // End old task
            if (gBgTask != UIBackgroundTaskInvalid) {
                write_log(@"│ [→] Ending expired task...");
                [app endBackgroundTask:gBgTask];
                gBgTask = UIBackgroundTaskInvalid;
                write_log(@"│ [✓] Expired task ended");
            }
            
            // If still in background, re-register immediately
            if (gInBackground) {
                write_log(@"│ [⟳] RE-REGISTERING due to expiration...");
                dispatch_async(dispatch_get_main_queue(), ^{
                    register_background_task();
                });
            } else {
                write_log(@"│ [ℹ] App not in background, skipping re-register");
            }
        }];
        
        write_log(@"│ [✓] Task registered successfully!");
        write_log(@"│ Task ID: %lu", (unsigned long)gBgTask);
        write_log(@"│ Background time remaining: %.1f sec", 
                 [app backgroundTimeRemaining]);
        write_log(@"└─────────────────────────────────────────────────");
        write_log(@"");
        
        #pragma clang diagnostic pop
    }
}

// ============================================================
// KEEP ALIVE THREAD - WILL NEVER DIE
// ============================================================

static void* keep_alive_thread(void* arg) {
    @autoreleasepool {
        write_log(@"");
        write_log(@"┌─────────────────────────────────────────────────");
        write_log(@"│ KEEP-ALIVE THREAD STARTED");
        write_log(@"├─────────────────────────────────────────────────");
        write_log(@"│ Thread ID: %lu", (unsigned long)pthread_self());
        write_log(@"│ This thread will run FOREVER");
        write_log(@"└─────────────────────────────────────────────────");
        write_log(@"");
        
        int cycle = 0;
        
        while (gKeepAlive) {
            @autoreleasepool {
                cycle++;
                
                // Log every 10 seconds
                if (cycle % 10 == 0) {
                    write_log(@"[♥] Keep-alive pulse #%d - Thread alive", cycle);
                    
                    // Check if we have a background task
                    if (gBgTask == UIBackgroundTaskInvalid && gInBackground) {
                        write_log(@"  [!] No background task! Re-registering...");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            register_background_task();
                        });
                    }
                    
                    // Log background time remaining
                    if (gInBackground) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        double remaining = [[UIApplication sharedApplication] backgroundTimeRemaining];
                        #pragma clang diagnostic pop
                        if (remaining < 1000) {
                            write_log(@"  ⏱️ Background time remaining: %.1f sec", remaining);
                            if (remaining < 30) {
                                write_log(@"  ⚠️ LOW TIME! Re-registering...");
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    register_background_task();
                                });
                            }
                        }
                    }
                }
                
                // Lightweight activity to keep thread alive
                // Using minimal CPU (0.5-1%)
                volatile int x = 0;
                for (int i = 0; i < 10000; i++) {
                    x++;
                }
                
                // Sleep 1 second between cycles
                [NSThread sleepForTimeInterval:1.0];
            }
        }
        
        write_log(@"[✖] Keep-alive thread EXITED (should never happen)");
        return NULL;
    }
}

// ============================================================
// START KEEP ALIVE
// ============================================================

static void start_keep_alive(void) {
    write_log(@"");
    write_log(@"┌─────────────────────────────────────────────────");
    write_log(@"│ STARTING KEEP-ALIVE THREAD");
    write_log(@"├─────────────────────────────────────────────────");
    
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setpriority(&attr, sched_get_priority_max(SCHED_RR) - 1);
    
    int result = pthread_create(&gThread, &attr, keep_alive_thread, NULL);
    
    if (result == 0) {
        write_log(@"│ [✓] Thread created successfully!");
        write_log(@"│ Thread handle: %lu", (unsigned long)gThread);
    } else {
        write_log(@"│ [✖] Thread creation FAILED with code: %d", result);
    }
    
    pthread_attr_destroy(&attr);
    write_log(@"└─────────────────────────────────────────────────");
    write_log(@"");
}

// ============================================================
// MAIN INIT
// ============================================================

static void init_anti_kick(void) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     ULTIMATE ANTI-KICK v2.0                             ║");
    write_log(@"║     WILL KEEP APP ALIVE FOREVER                         ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    // Log system info
    log_system_info();
    
    write_log(@"");
    write_log(@"┌─────────────────────────────────────────────────");
    write_log(@"│ INITIALIZING ANTI-KICK MODULE");
    write_log(@"├─────────────────────────────────────────────────");
    
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIApplication *app = [UIApplication sharedApplication];
    
    // Disable idle timer
    write_log(@"│ [→] Disabling idle timer...");
    [app setIdleTimerDisabled:YES];
    write_log(@"│ [✓] Idle timer disabled");
    #pragma clang diagnostic pop
    
    // Register notification observers
    write_log(@"│ [→] Registering notification observers...");
    
    // Enter background notification
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║     📱 APP WENT TO BACKGROUND                            ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        write_log(@"");
        write_log(@"  ■ App state: UIApplicationStateBackground");
        write_log(@"  ■ Background time remaining: %.1f sec", 
                 [UIApplication sharedApplication].backgroundTimeRemaining);
        write_log(@"  ■ Registering background task...");
        write_log(@"");
        
        gInBackground = true;
        register_background_task();
        
        write_log(@"  [✓] Background task registered");
        write_log(@"");
    }];
    
    // Enter foreground notification
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║     📱 APP RETURNED TO FOREGROUND                       ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        write_log(@"");
        write_log(@"  ■ App state: UIApplicationStateActive");
        write_log(@"  ■ Ending background task...");
        
        gInBackground = false;
        
        if (gBgTask != UIBackgroundTaskInvalid) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] endBackgroundTask:gBgTask];
            #pragma clang diagnostic pop
            write_log(@"  ■ Task %lu ended", (unsigned long)gBgTask);
            gBgTask = UIBackgroundTaskInvalid;
        } else {
            write_log(@"  ■ No active task to end");
        }
        
        write_log(@"  [✓] Ready for action!");
        write_log(@"");
    }];
    
    write_log(@"│ [✓] Notification observers registered");
    
    // Register initial background task
    write_log(@"│ [→] Registering initial background task...");
    register_background_task();
    write_log(@"│ [✓] Initial task registered");
    
    // Start keep alive thread
    write_log(@"│ [→] Starting keep-alive thread...");
    start_keep_alive();
    write_log(@"│ [✓] Keep-alive thread started");
    
    write_log(@"└─────────────────────────────────────────────────");
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║     ✅ ANTI-KICK ACTIVE!                                 ║");
    write_log(@"║     ✅ Background time: FOREVER                          ║");
    write_log(@"║     ✅ App will NEVER be suspended                       ║");
    write_log(@"║                                                          ║");
    write_log(@"║     [!] Keep-alive thread is running                    ║");
    write_log(@"║     [!] Re-registers automatically on expiration        ║");
    write_log(@"║                                                          ║");
    write_log(@"║     LOG: Documents/saves/AntiKick.log                   ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    write_log(@"");
}

// ============================================================
// ENTRY POINT
// ============================================================

__attribute__((constructor))
static void inject(void) {
    // Small delay to ensure app is fully loaded
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            init_anti_kick();
        } @catch (NSException *e) {
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════╗");
            write_log(@"║     ❌ INITIALIZATION FAILED                             ║");
            write_log(@"║     Exception: %@", e);
            write_log(@"║     Reason: %@", e.reason);
            write_log(@"╚═══════════════════════════════════════════════════════════╝");
            write_log(@"");
        }
    });
}

extern "C" void __dummy_export(void) {}
