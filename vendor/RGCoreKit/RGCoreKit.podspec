#
#  Be sure to run `pod spec lint RGCoreKit.podspec' to ensure this is a
#  valid spec and to remove all comments including this before submitting the spec.
#
#  To learn more about Podspec attributes see https://guides.cocoapods.org/syntax/podspec.html
#  To see working Podspecs in the CocoaPods repo see https://github.com/CocoaPods/Specs/
#

Pod::Spec.new do |spec|
  spec.name         = "RGCoreKit"
  spec.version      = "0.0.2"
  spec.summary      = "A short description of RGCoreKit."
  spec.homepage     = "https://www.rokid.com/"
  spec.license      = {"type" => "Copyright", "text" => " Copyright 2025 Rokid "}
  spec.author       = 'Rokid R&D'
  spec.source       = { :git => "https://github.com/rokid", :tag => "#{spec.version}" }
  spec.source_files = 'Classes/**/*'
  spec.resource = 'Assets/**/*'
  spec.pod_target_xcconfig = {
#    "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "arm64",
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
    "APPLICATION_EXTENSION_API_ONLY" => "NO"
  }
  spec.swift_version = '5.0'
  spec.platforms = {"ios" => "13.0"}
  
  spec.dependency 'CocoaLumberjack/Swift'
end
