#
#  Be sure to run `pod spec lint RGCxrServer.podspec' to ensure this is a
#  valid spec and to remove all comments including this before submitting the spec.
#
#  To learn more about Podspec attributes see https://guides.cocoapods.org/syntax/podspec.html
#  To see working Podspecs in the CocoaPods repo see https://github.com/CocoaPods/Specs/
#

Pod::Spec.new do |spec|
  spec.name         = "RGCxrServer"
  spec.version      = "0.0.1"
  spec.summary      = "A short description of RGCxrServer."
  spec.homepage     = "https://www.rokid.com/"
  spec.license      = {"type" => "Copyright", "text" => " Copyright 2025 Rokid "}
  spec.author       = 'Rokid R&D'
  spec.source       = { :git => "https://github.com/rokid", :tag => "#{spec.version}" }
  spec.source_files = ['RGCxrServer/Classes/**/*', 'RGCxrCore/Classes/**/*.swift']
  spec.resource = 'RGCxrServer/Assets/**/*'
  spec.pod_target_xcconfig = {
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
    "APPLICATION_EXTENSION_API_ONLY" => "NO"
  }
  spec.swift_version = '5.0'
  spec.platforms = {"ios" => "13.0"}
  spec.frameworks = 'Foundation', 'Network', 'NetworkExtension'
  
  spec.dependency 'RGCoreKit'
  spec.dependency 'RGCxrKit'
end
