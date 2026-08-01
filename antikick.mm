// antikick.mm - FIXED AUDIO

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <pthread.h>

#define TIMER_INTERVAL 5.0

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static bool inBackground = false;
static bool isInitialized = false;
static dispatch_source_t timer = NULL;
static AVAudioPlayer *player = nil;

static void write_log(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *logPath = [[paths firstObject] stringByAppendingPathComponent:@"saves/AntiKick.log"];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];
        
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSLog(@"%@", entry);
    }
}

static void init_audio(void) {
    @autoreleasepool {
        write_log(@"  Initializing audio...");
        
        NSError *error = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        
        [session setCategory:AVAudioSessionCategoryPlayback 
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                       error:&error];
        if (error) {
            write_log(@"  ❌ Session error: %@", error);
            return;
        }
        
        [session setActive:YES error:&error];
        if (error) {
            write_log(@"  ❌ Activate error: %@", error);
            return;
        }
        
        // Создаём WAV файл в памяти (1 секунда тишины)
        // WAV header + silence data
        int sampleRate = 44100;
        int duration = 1;
        int numSamples = sampleRate * duration;
        int dataSize = numSamples * 2; // 16-bit
        
        // WAV header (44 bytes)
        NSMutableData *wavData = [NSMutableData data];
        
        // RIFF header
        [wavData appendBytes:"RIFF" length:4];
        int chunkSize = 36 + dataSize;
        [wavData appendBytes:&chunkSize length:4];
        [wavData appendBytes:"WAVE" length:4];
        
        // fmt chunk
        [wavData appendBytes:"fmt " length:4];
        int fmtSize = 16;
        [wavData appendBytes:&fmtSize length:4];
        short audioFormat = 1;
        [wavData appendBytes:&audioFormat length:2];
        short numChannels = 1;
        [wavData appendBytes:&numChannels length:2];
        int sampleRate2 = 44100;
        [wavData appendBytes:&sampleRate2 length:4];
        int byteRate = 44100 * 2;
        [wavData appendBytes:&byteRate length:4];
        short blockAlign = 2;
        [wavData appendBytes:&blockAlign length:2];
        short bitsPerSample = 16;
        [wavData appendBytes:&bitsPerSample length:2];
        
        // data chunk
        [wavData appendBytes:"data" length:4];
        [wavData appendBytes:&dataSize length:4];
        
        // silence data
        short *samples = (short*)malloc(dataSize);
        memset(samples, 0, dataSize);
        [wavData appendBytes:samples length:dataSize];
        free(samples);
        
        // Create player
        player = [[AVAudioPlayer alloc] initWithData:wavData error:&error];
        if (error) {
            write_log(@"  ❌ Player error: %@", error);
            return;
        }
        
        player.numberOfLoops = -1;
        player.volume = 0.0;
        [player prepareToPlay];
        [player play];
        
        write_log(@"  ✅ Audio playing (silent)");
    }
}

static void register_task(void) {
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;
        
        if ([app applicationState] != UIApplicationStateBackground) {
            write_log(@"  ℹ️ Not in background, skipping");
            return;
        }
        
        double remaining = [app backgroundTimeRemaining];
        if (remaining > 1000) {
            write_log(@"  ℹ️ No background time (%.1f)", remaining);
            return;
        }
        
        if (bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
        
        bgTask = [app beginBackgroundTaskWithName:@"AntiKick" 
                                expirationHandler:^{
            write_log(@"  ⚠️ Task expired");
            if (bgTask != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }
            if (inBackground) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    register_task();
                });
            }
        }];
        
        write_log(@"  ✅ Task: %lu", (unsigned long)bgTask);
    }
}

static void keep_alive(void) {
    @autoreleasepool {
        static int tick = 0;
        tick++;
        
        if (!inBackground) return;
        
        UIApplication *app = [UIApplication sharedApplication];
        double remaining = [app backgroundTimeRemaining];
        
        if (tick % 30 == 0) {
            write_log(@"  [♥] Tick #%d, remaining: %.1f", tick, remaining);
        }
        
        if (remaining < 30.0 && remaining > 0) {
            write_log(@"  🔄 Refreshing (%.1f sec)", remaining);
            dispatch_async(dispatch_get_main_queue(), ^{
                register_task();
            });
        }
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            write_log(@"");
            write_log(@"ANTI-KICK v5.1");
            
            UIApplication *app = [UIApplication sharedApplication];
            [app setIdleTimerDisabled:YES];
            write_log(@"  ✅ Idle timer disabled");
            
            init_audio();
            
            // Timer
            dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, TIMER_INTERVAL * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    keep_alive();
                });
            });
            dispatch_resume(timer);
            write_log(@"  ✅ Timer started");
            
            // Notifications
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                               object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *n) {
                write_log(@"");
                write_log(@"📱 BACKGROUND");
                inBackground = YES;
                register_task();
            }];
            
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                               object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *n) {
                write_log(@"");
                write_log(@"📱 FOREGROUND");
                inBackground = NO;
                if (bgTask != UIBackgroundTaskInvalid) {
                    [app endBackgroundTask:bgTask];
                    bgTask = UIBackgroundTaskInvalid;
                    write_log(@"  ✅ Task ended");
                }
            }];
            
            write_log(@"");
            write_log(@"✅ ANTI-KICK ACTIVE");
            write_log(@"");
            
        } @catch (NSException *e) {
            write_log(@"❌ Error: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
