#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Конструктор — вызывается при загрузке библиотеки
__attribute__((constructor))
static void onLibraryLoad() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Создаём уведомление как у "низкого заряда"
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:@"⚠️ Библиотека загружена"
            message:@"Tweak.dylib успешно внедрена в процесс"
            preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *okAction = [UIAlertAction 
            actionWithTitle:@"OK" 
            style:UIAlertActionStyleDefault 
            handler:nil];
        [alert addAction:okAction];
        
        // Показываем поверх всего
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        if (!keyWindow) {
            // Запасной вариант: ищем любое окно
            keyWindow = [UIApplication sharedApplication].windows.firstObject;
        }
        [keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

// Деструктор — при выгрузке (опционально)
__attribute__((destructor))
static void onLibraryUnload() {
    NSLog(@"🔴 Tweak.dylib выгружена");
}
