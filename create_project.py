#!/usr/bin/env python3
import os
import subprocess

project_name = "HitboxEngine"
target_name = "HitboxEngine"

# Создаем Xcode проект
subprocess.run([
    "xcodebuild", "-create-xcframework", 
    "-project", "HitboxEngine.xcodeproj"
], capture_output=True)

# Используем xcodeproj gem для создания проекта
subprocess.run([
    "ruby", "-e", f"""
    require 'xcodeproj'
    
    project = Xcodeproj::Project.new('{project_name}.xcodeproj')
    target = project.new_target(:dynamic_library, '{target_name}', :ios)
    
    # Добавляем файлы
    group = project.main_group.find_subpath('{target_name}', true)
    
    ['HitboxEngine.h', 'HitboxEngine.mm', 'KittyMemory.h', 'main.mm'].each do |file|
        group.new_file(file)
        target.add_file_reference(group.files.last)
    end
    
    # Настройки сборки
    target.build_configurations.each do |config|
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '11.0'
        config.build_settings['SDKROOT'] = 'iphoneos'
        config.build_settings['MACH_O_TYPE'] = 'mh_dylib'
        config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
        config.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
        config.build_settings['CLANG_ENABLE_OBJC_WEAK'] = 'YES'
        config.build_settings['GCC_OPTIMIZATION_LEVEL'] = 's'
        config.build_settings['ENABLE_BITCODE'] = 'NO'
        config.build_settings['STRIP_INSTALLED_PRODUCT'] = 'YES'
        config.build_settings['DEPLOYMENT_POSTPROCESSING'] = 'YES'
    end
    
    project.save
    """
])
