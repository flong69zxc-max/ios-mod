#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor)) void entry() {
    // Ждем пару секунд пока игра прогрузит UI, затем показываем окно
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Успех!" 
                                                                   message:@"Твоя dylib успешно загрузилась в игру!" 
                                                            preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
        
        // Получаем корневое окно и показываем алерт
        UIWindow *window = [[[UIApplication sharedApplication] windows] firstObject];
        [window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}
