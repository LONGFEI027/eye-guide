#
#  Be sure to run `pod spec lint RGCxrKit.podspec' to ensure this is a
#  valid spec and to remove all comments including this before submitting the spec.
#
#  To learn more about Podspec attributes see https://guides.cocoapods.org/syntax/podspec.html
#  To see working Podspecs in the CocoaPods repo see https://github.com/CocoaPods/Specs/
#

Pod::Spec.new do |spec|
  spec.name         = "RGCxrKit"
  spec.version      = "0.0.2"
  spec.summary      = "A short description of RGCxrKit."
  spec.homepage     = "https://www.rokid.com/"
  spec.license      = {"type" => "Copyright", "text" => " Copyright 2025 Rokid "}
  spec.author       = 'Rokid R&D'
  spec.source       = { :git => "https://github.com/rokid", :tag => "#{spec.version}" }
  spec.source_files = ['RGCxrKit/Classes/**/*', 'RGCxrCore/Classes/**/*.{h,mm,c,m,cpp,swift}']
  spec.project_header_files = 'RGCxrCore/Classes/**/*.h'
  spec.public_header_files = 'RGCxrKit-Umbrella.h'
  spec.resource = 'RGCxrKit/Assets/**/*'
  spec.vendored_libraries = 'RGCxrCore/Vendors/libopus.a'
  # OC/Swift 混编 + C++ 编译器兼容性配置
  spec.pod_target_xcconfig = {
    # Swift 模块稳定性 - 确保不同 Swift 编译器版本兼容
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
    "DEFINES_MODULE" => "YES",
    "CLANG_ENABLE_MODULES" => "YES",
    
    # Swift 编译优化
    "SWIFT_COMPILATION_MODE" => "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL" => "-Owholemodule",
    
    # C++ 支持（Socket 模块使用 C++）
    "CLANG_CXX_LANGUAGE_STANDARD" => "gnu++17",
    "CLANG_CXX_LIBRARY" => "libc++",
    
    # 预处理宏
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) CXR_PLATFORM_APPLE=1",
    
    # 模块映射 - 指定模块映射文件路径
    "MODULEMAP_FILE" => "$(PODS_TARGET_SRCROOT)/RGCxrKit/Module/module.modulemap",
    # Swift 包含路径
    "SWIFT_INCLUDE_PATHS" => "$(PODS_TARGET_SRCROOT)/RGCxrKit/Module",
    
    # 其他设置
    "APPLICATION_EXTENSION_API_ONLY" => "NO",
    "ENABLE_BITCODE" => "NO",
    "ONLY_ACTIVE_ARCH" => "NO",
    
    'OTHER_LDFLAGS' => '-lopus'
  }
  
  spec.user_target_xcconfig = {
    # 确保集成方也启用模块
    "CLANG_ENABLE_MODULES" => "YES"
  }
  
  spec.preserve_path = ['RGCxrKit/Module/module.modulemap', 'Framework.xcconfig', 'RGCxrKit-Umbrella.h']
  spec.swift_version = '5.0'
  spec.platforms = {"ios" => "14.0"}
  spec.ios.deployment_target = '14.0'
  
  # 链接库
  spec.frameworks = 'Foundation', 'CoreBluetooth', 'ExternalAccessory'
  spec.libraries = 'c++'
  
  spec.dependency 'RGCoreKit'
end
