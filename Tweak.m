#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

__attribute__((constructor)) static void init() {
    NSLog(@"[LowPowerMock] Дилиба загружена!");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"Режим энергосбережения";
        content.body = @"Режим энергосбережения снижает уровень производительности и временную активность в фоновом режиме, такую как загрузка почты.";
        content.sound = [UNNotificationSound defaultSound];
        
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1.0 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"LowPowerMockNotification" 
                                                                               content:content 
                                                                               trigger:trigger];
        
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[LowPowerMock] Ошибка: %@", error.localizedDescription);
            } else {
                NSLog(@"[LowPowerMock] Уведомление отправлено!");
            }
        }];
    });
}
