#include <stdio.h>

// Функция выполнится при инъекции библиотеки в игру
__attribute__((constructor)) void entry() {
    printf("=== MOD LOADED SUCCESSFULLY ===\n");
}
