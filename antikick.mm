// antikick.mm

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static bool inBackground = false;

static void write_log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *logPath = [[paths firstObject] stringByAppendingPathComponent:@"saves/AntiKick.log"];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"%@", entry);
}

static void registerTask() {
    UIApplication *app = [UIApplication sharedApplication];
    
    if (bgTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }
    
    bgTask = [app beginBackgroundTaskWithName:@"AntiKick" expirationHandler:^{
        write_log(@"Task expired, re-register...");
        [app endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
        if (inBackground) registerTask();
    }];
    
    write_log([NSString stringWithFormat:@"Task registered: %lu", bgTask]);
}

__attribute__((constructor))
static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        write_log(@"AntiKick started");
        
        [UIApplication sharedApplication].idleTimerDisabled = YES;
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                           object:nil
                                                            queue:nil
                                                       usingBlock:^(NSNotification *n) {
            inBackground = YES;
            write_log(@"Background - register task");
            registerTask();
        }];
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                           object:nil
                                                            queue:nil
                                                       usingBlock:^(NSNotification *n) {
            inBackground = NO;
            if (bgTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
                write_log(@"Foreground - task ended");
            }
        }];
        
        registerTask();
        write_log(@"Ready");
    });
}

extern "C" void __dummy_export(void) {}
