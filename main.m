#import <CoreFoundation/CoreFoundation.h>

__attribute__((constructor))
static void onLoad(void) {
    NSLog(@"✅ main.dylib загружена! Процесс: %@", [[NSProcessInfo processInfo] processName]);

    CFUserNotificationRef notification = CFUserNotificationCreate(
        kCFAllocatorDefault,
        0,
        kCFUserNotificationPlainAlertLevel,
        NULL,
        (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCFUserNotificationAlertHeaderKey: @"📢 Библиотека загружена",
            (__bridge NSString *)kCFUserNotificationAlertMessageKey: @"main.dylib работает!"
        }
    );
    if (notification) {
        CFUserNotificationReceiveResponse(notification, 0, NULL);
        CFRelease(notification);
    }
}
