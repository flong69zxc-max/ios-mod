// main.m
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

// Паттерн хитбоксов (только первый хитбокс для поиска)
// HEAD: 9A 99 19 3E
const float HITBOX_PATTERN[] = {
    0.15f   // HEAD = 9A 99 19 3E
};

const char* HITBOX_NAMES[] = {
    "HEAD",
    "TORSO_1",
    "TORSO_2",
    "MID",
    "LEFTARM",
    "RIGHTARM",
    "LEFTLEG_1",
    "RIGHTLEG_1",
    "LEFTLEG_2",
    "RIGHTLEG_2"
};

// Функция для поиска сигнатуры в памяти
void* find_pattern_in_memory(const void* start, size_t size, const void* pattern, size_t pattern_size) {
    if (size < pattern_size) return NULL;
    
    const uint8_t* bytes = (const uint8_t*)start;
    const uint8_t* pat = (const uint8_t*)pattern;
    
    for (size_t i = 0; i <= size - pattern_size; i++) {
        if (memcmp(bytes + i, pat, pattern_size) == 0) {
            return (void*)((uintptr_t)start + i);
        }
    }
    return NULL;
}

// Проверка валидности оффсета (все 10 хитбоксов через 0x20)
BOOL validate_hitbox_offsets(void* base_addr) {
    float* hitbox = (float*)base_addr;
    const float EXPECTED_VALUES[] = {
        0.15f,   // HEAD
        0.012f,  // TORSO_1
        0.25f,   // TORSO_2
        0.25f,   // MID
        0.04f,   // LEFTARM
        0.04f,   // RIGHTARM
        0.012f,  // LEFTLEG_1
        0.012f,  // RIGHTLEG_1
        0.15f,   // LEFTLEG_2
        0.15f    // RIGHTLEG_2
    };
    
    for (int i = 0; i < 10; i++) {
        float* addr = (float*)((uintptr_t)base_addr + (i * 0x20));
        float value = *addr;
        // Сравниваем с погрешностью 0.001
        if (fabs(value - EXPECTED_VALUES[i]) > 0.001f) {
            return NO;
        }
    }
    return YES;
}

// Функция для поиска в библиотеке
void* find_in_library(const char* library_name) {
    uint32_t count = _dyld_image_count();
    size_t pattern_size = sizeof(HITBOX_PATTERN);
    
    for (uint32_t i = 0; i < count; i++) {
        const char* image_name = _dyld_get_image_name(i);
        if (image_name && strstr(image_name, library_name) != NULL) {
            const struct mach_header* header = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            
            struct load_command* cmd = (struct load_command*)((uintptr_t)header + sizeof(struct mach_header));
            struct segment_command_64* seg_cmd = NULL;
            
            for (uint32_t j = 0; j < header->ncmds; j++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    seg_cmd = (struct segment_command_64*)cmd;
                    if (strcmp(seg_cmd->segname, "__TEXT") == 0) {
                        void* base_addr = (void*)((uintptr_t)header + slide);
                        size_t seg_size = seg_cmd->vmsize;
                        
                        // Ищем паттерн HEAD
                        void* found = find_pattern_in_memory(base_addr, seg_size, HITBOX_PATTERN, pattern_size);
                        
                        // Проверяем, что найден правильный оффсет (все хитбоксы через 0x20)
                        while (found != NULL) {
                            if (validate_hitbox_offsets(found)) {
                                return found;
                            }
                            // Ищем следующее вхождение
                            uintptr_t next_pos = (uintptr_t)found + 1;
                            if (next_pos >= (uintptr_t)base_addr + seg_size) break;
                            found = find_pattern_in_memory((void*)next_pos, 
                                                          seg_size - (next_pos - (uintptr_t)base_addr), 
                                                          HITBOX_PATTERN, 
                                                          pattern_size);
                        }
                    }
                }
                cmd = (struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
            }
        }
    }
    return NULL;
}

// Главная функция
__attribute__((constructor))
void init() {
    @autoreleasepool {
        NSLog(@"[Hitbox Scanner] Starting scan...");
        NSLog(@"[Hitbox Scanner] Looking for HEAD pattern: 9A 99 19 3E");
        
        const char* lib_name = "blackrussia-client";
        void* found_addr = find_in_library(lib_name);
        
        if (found_addr) {
            uintptr_t offset = (uintptr_t)found_addr;
            NSLog(@"\n========================================");
            NSLog(@"[Hitbox Scanner] ✅ HITBOX OFFSET FOUND!");
            NSLog(@"[Hitbox Scanner] Base offset: 0x%llX", (unsigned long long)offset);
            NSLog(@"========================================\n");
            
            // Выводим каждый хитбокс через 0x20
            for (int i = 0; i < 10; i++) {
                uintptr_t hitbox_addr = offset + (i * 0x20);
                float* value = (float*)hitbox_addr;
                NSLog(@"  [%d] %-12s: 0x%llX -> %.6f", 
                      i,
                      HITBOX_NAMES[i], 
                      (unsigned long long)hitbox_addr, 
                      *value);
            }
            
            NSLog(@"\n========================================");
            NSLog(@"[Hitbox Scanner] You can use offset: 0x%llX", (unsigned long long)offset);
            NSLog(@"========================================");
            
        } else {
            NSLog(@"[Hitbox Scanner] ❌ Pattern NOT found in %s", lib_name);
            
            // Ищем во всех библиотеках
            NSLog(@"[Hitbox Scanner] Searching in ALL libraries...");
            uint32_t count = _dyld_image_count();
            
            for (uint32_t i = 0; i < count; i++) {
                const char* image_name = _dyld_get_image_name(i);
                if (image_name) {
                    const struct mach_header* header = _dyld_get_image_header(i);
                    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
                    
                    struct load_command* cmd = (struct load_command*)((uintptr_t)header + sizeof(struct mach_header));
                    for (uint32_t j = 0; j < header->ncmds; j++) {
                        if (cmd->cmd == LC_SEGMENT_64) {
                            struct segment_command_64* seg_cmd = (struct segment_command_64*)cmd;
                            if (strcmp(seg_cmd->segname, "__TEXT") == 0) {
                                void* base = (void*)((uintptr_t)header + slide);
                                void* found = find_pattern_in_memory(base, seg_cmd->vmsize, 
                                                                   HITBOX_PATTERN, 
                                                                   sizeof(HITBOX_PATTERN));
                                if (found && validate_hitbox_offsets(found)) {
                                    NSLog(@"  ✅ Found valid hitbox offsets in: %s at 0x%llX", 
                                          image_name, 
                                          (unsigned long long)((uintptr_t)found));
                                    
                                    // Выводим несколько хитбоксов для проверки
                                    for (int k = 0; k < 10; k++) {
                                        float* val = (float*)((uintptr_t)found + (k * 0x20));
                                        NSLog(@"    %s: 0x%llX -> %.6f", 
                                              HITBOX_NAMES[k],
                                              (unsigned long long)((uintptr_t)found + (k * 0x20)),
                                              *val);
                                    }
                                    break;
                                }
                            }
                        }
                        cmd = (struct load_command*)((uintptr_t)cmd + cmd->cmdsize);
                    }
                }
            }
        }
    }
}
