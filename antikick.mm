// antikick.mm - ULTIMATE v4.0 (10/10)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/task.h>

// ============================================================
// CONFIGURATION
// ============================================================
#define LOG_MAX_SIZE (1024 * 1024) // 1MB max log size
#define TIMER_INTERVAL 5.0 // seconds
#define INIT_DELAY 0.5 // seconds

// ============================================================
// STATE
// ============================================================
static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static bool inBackground = false;
static bool isInitialized = false;
static bool isCleaningUp = false;
static int taskCounter = 0;
static int backgroundEnterCount = 0;
static NSTimer *keepAliveTimer = nil;
static NSMutableArray *notificationObservers = nil;

// ============================================================
// LOGGING WITH ROTATION
// ============================================================
static void rotate_log_if_needed(NSString *logPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:logPath error:nil];
    unsigned long long size = [attrs fileSize];
    
    if (size > LOG_MAX_SIZE) {
        // Rename old log
        NSString *backupPath = [logPath stringByAppendingString:@".old"];
        [fm removeItemAtPath:backupPath error:nil];
        [fm moveItemAtPath:logPath toPath:backupPath error:nil];
    }
}

static void write_log(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        // Get documents path
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths firstObject];
        NSString *savesPath = [documentsPath stringByAppendingPathComponent:@"saves"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:savesPath]) {
            [fileManager createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"AntiKick.log"];
        
        // Rotate log if too large
        rotate_log_if_needed(logPath);
        
        // Timestamp
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        
        NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        // Write to file
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
// MEMORY CHECK
// ============================================================
static void log_memory_usage(void) {
    struct task_basic_info info;
    mach_msg_type_number_t size = TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    
    if (kr == KERN_SUCCESS) {
        float memoryMB = (float)info.resident_size / 1024.0 / 1024.0;
        float virtualMB = (float)info.virtual_size / 1024.0 / 1024.0;
        write_log(@"  Memory: %.2f MB resident, %.2f MB virtual", memoryMB, virtualMB);
    }
}

// ============================================================
// CLEANUP
// ============================================================
static void cleanup_anti_kick(void) {
    if (isCleaningUp) return;
    isCleaningUp = YES;
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║  🧹 CLEANUP STARTED                                     ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    
    // Invalidate timer
    if (keepAliveTimer) {
        [keepAliveTimer invalidate];
        keepAliveTimer = nil;
        write_log(@"  ✅ Timer invalidated");
    }
    
    // Remove notification observers
    if (notificationObservers) {
        for (id observer in notificationObservers) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
        }
        [notificationObservers removeAllObjects];
        notificationObservers = nil;
        write_log(@"  ✅ Observers removed");
    }
    
    // End background task
    if (bgTask != UIBackgroundTaskInvalid) {
        UIApplication *app = [UIApplication sharedApplication];
        if (app) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
            write_log(@"  ✅ Background task ended");
        }
    }
    
    isInitialized = NO;
    write_log(@"  ✅ Cleanup complete");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
}

// ============================================================
// BACKGROUND TASK REGISTRATION
// ============================================================
static void register_background_task(void) {
    @autoreleasepool {
        if (isCleaningUp) {
            write_log(@"  ⚠️ Skipping registration - cleanup in progress");
            return;
        }
        
        taskCounter++;
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║  BACKGROUND TASK #%d                                    ║", taskCounter);
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) {
            write_log(@"  ❌ ERROR: UIApplication is NULL!");
            return;
        }
        
        // Check app state
        UIApplicationState state = [app applicationState];
        write_log(@"  App state: %ld", (long)state);
        
        // End existing task if any
        if (bgTask != UIBackgroundTaskInvalid) {
            write_log(@"  Ending existing task (ID: %lu)...", (unsigned long)bgTask);
            @try {
                [app endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
                write_log(@"  ✅ Existing task ended");
            } @catch (NSException *e) {
                write_log(@"  ❌ Exception: %@", e);
                bgTask = UIBackgroundTaskInvalid;
            }
        }
        
        // Register new task
        write_log(@"  Registering new task...");
        
        @try {
            bgTask = [app beginBackgroundTaskWithName:@"AntiKickTask" 
                                    expirationHandler:^{
                write_log(@"");
                write_log(@"  ⚠️ EXPIRATION HANDLER TRIGGERED!");
                write_log(@"  Task ID: %lu", (unsigned long)bgTask);
                double remaining = [app backgroundTimeRemaining];
                write_log(@"  Time remaining: %.1f sec", remaining);
                write_log(@"  In background: %@", inBackground ? @"YES" : @"NO");
                
                // End expired task
                if (bgTask != UIBackgroundTaskInvalid) {
                    @try {
                        [app endBackgroundTask:bgTask];
                        bgTask = UIBackgroundTaskInvalid;
                        write_log(@"  ✅ Expired task ended");
                    } @catch (NSException *e) {
                        write_log(@"  ❌ Exception: %@", e);
                        bgTask = UIBackgroundTaskInvalid;
                    }
                }
                
                // Re-register if in background and not cleaning up
                if (inBackground && !isCleaningUp) {
                    write_log(@"  🔄 Re-registering...");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        register_background_task();
                    });
                }
            }];
            
            write_log(@"  ✅ Task registered!");
            write_log(@"    ID: %lu", (unsigned long)bgTask);
            write_log(@"    Remaining: %.1f sec", [app backgroundTimeRemaining]);
            
        } @catch (NSException *e) {
            write_log(@"  ❌ Exception: %@", e);
            bgTask = UIBackgroundTaskInvalid;
        }
        
        log_memory_usage();
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
    }
}

// ============================================================
// KEEP ALIVE TIMER
// ============================================================
static void keep_alive_tick(NSTimer *timer) {
    @autoreleasepool {
        if (isCleaningUp || !isInitialized) return;
        
        static int tickCounter = 0;
        tickCounter++;
        
        if (tickCounter % (int)(30.0 / TIMER_INTERVAL) == 0) {
            write_log(@"");
            write_log(@"┌─────────────────────────────────────────────────");
            write_log(@"│ KEEP-ALIVE TICK #%d", tickCounter);
            write_log(@"├─────────────────────────────────────────────────");
            write_log(@"│ In background: %@", inBackground ? @"YES" : @"NO");
            write_log(@"│ Task ID: %lu", (unsigned long)bgTask);
            write_log(@"│ Task valid: %@", bgTask != UIBackgroundTaskInvalid ? @"YES" : @"NO");
            
            UIApplication *app = [UIApplication sharedApplication];
            if (app && inBackground) {
                double remaining = [app backgroundTimeRemaining];
                write_log(@"│ Time remaining: %.1f sec", remaining);
                
                // Auto-refresh if time is low
                if (remaining < 60.0 && remaining > 0 && !isCleaningUp) {
                    write_log(@"│ ⚠️ Time low! Refreshing...");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        register_background_task();
                    });
                }
            }
            
            log_memory_usage();
            write_log(@"└─────────────────────────────────────────────────");
        }
    }
}

// ============================================================
// APPLICATION STATE CHANGES
// ============================================================
static void app_did_enter_background(NSNotification *notification) {
    if (isCleaningUp) return;
    
    backgroundEnterCount++;
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║  📱 BACKGROUND (#%d)", backgroundEnterCount);
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    
    inBackground = YES;
    
    UIApplication *app = [UIApplication sharedApplication];
    if (app) {
        write_log(@"  Time remaining: %.1f sec", [app backgroundTimeRemaining]);
        write_log(@"  State: %ld", (long)[app applicationState]);
    }
    log_memory_usage();
    
    register_background_task();
}

static void app_will_enter_foreground(NSNotification *notification) {
    if (isCleaningUp) return;
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════╗");
    write_log(@"║  📱 FOREGROUND                                          ║");
    write_log(@"╚═══════════════════════════════════════════════════════════╝");
    
    inBackground = NO;
    
    if (bgTask != UIBackgroundTaskInvalid) {
        UIApplication *app = [UIApplication sharedApplication];
        if (app) {
            write_log(@"  Ending task %lu...", (unsigned long)bgTask);
            @try {
                [app endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
                write_log(@"  ✅ Task ended");
            } @catch (NSException *e) {
                write_log(@"  ❌ Exception: %@", e);
                bgTask = UIBackgroundTaskInvalid;
            }
        }
    }
    log_memory_usage();
}

// ============================================================
// MAIN INIT
// ============================================================
static void init_anti_kick(void) {
    @autoreleasepool {
        if (isInitialized) {
            write_log(@"⚠️ Already initialized");
            return;
        }
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║  🔥 ANTI-KICK v4.0 (10/10)                              ║");
        write_log(@"║  Production Ready                                       ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) {
            write_log(@"❌ UIApplication is NULL!");
            return;
        }
        
        // Disable idle timer
        write_log(@"  Step 1: Disabling idle timer...");
        @try {
            [app setIdleTimerDisabled:YES];
            write_log(@"  ✅ Done");
        } @catch (NSException *e) {
            write_log(@"  ❌ Failed: %@", e);
        }
        
        // Initialize observers array
        notificationObservers = [[NSMutableArray alloc] init];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        
        // Register observers
        write_log(@"  Step 2: Registering observers...");
        @try {
            id observer;
            
            observer = [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                                           object:nil
                                            queue:[NSOperationQueue mainQueue]
                                       usingBlock:^(NSNotification *note) {
                                           app_did_enter_background(note);
                                       }];
            [notificationObservers addObject:observer];
            
            observer = [center addObserverForName:UIApplicationWillEnterForegroundNotification
                                           object:nil
                                            queue:[NSOperationQueue mainQueue]
                                       usingBlock:^(NSNotification *note) {
                                           app_will_enter_foreground(note);
                                       }];
            [notificationObservers addObject:observer];
            
            write_log(@"  ✅ Done (%lu observers)", (unsigned long)notificationObservers.count);
        } @catch (NSException *e) {
            write_log(@"  ❌ Failed: %@", e);
        }
        
        // Start timer with proper target
        write_log(@"  Step 3: Starting timer (interval: %.1fs)...", TIMER_INTERVAL);
        @try {
            // Create a simple object to hold timer callback
            // Using dispatch_source timer instead for iOS 10+
            dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, TIMER_INTERVAL * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    keep_alive_tick(nil);
                });
            });
            dispatch_resume(timer);
            
            // Store timer in a global static
            static dispatch_source_t globalTimer = NULL;
            globalTimer = timer;
            
            write_log(@"  ✅ Done (dispatch_source timer)");
        } @catch (NSException *e) {
            write_log(@"  ❌ Failed: %@", e);
        }
        
        // Register initial task
        write_log(@"  Step 4: Registering initial task...");
        register_background_task();
        
        isInitialized = YES;
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════╗");
        write_log(@"║  ✅ ANTI-KICK INITIALIZED (10/10)                       ║");
        write_log(@"║  Log: Documents/saves/AntiKick.log                      ║");
        write_log(@"║  Interval: %.1f sec                                     ║", TIMER_INTERVAL);
        write_log(@"║  Status: ACTIVE                                         ║");
        write_log(@"╚═══════════════════════════════════════════════════════════╝");
        write_log(@"");
    }
}

// ============================================================
// ENTRY POINT
// ============================================================
__attribute__((constructor))
static void inject(void) {
    // Use short delay with async to let app load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, INIT_DELAY * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            init_anti_kick();
        } @catch (NSException *e) {
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════╗");
            write_log(@"║  ❌ INIT FAILED!                                         ║");
            write_log(@"║  Exception: %@", e);
            write_log(@"╚═══════════════════════════════════════════════════════════╝");
        }
    });
}

// ============================================================
// CLEANUP ON UNLOAD (if possible)
// ============================================================
__attribute__((destructor))
static void unload(void) {
    cleanup_anti_kick();
}

extern "C" void __dummy_export(void) {}
