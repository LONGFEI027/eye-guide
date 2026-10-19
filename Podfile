# Rokid CXR-L SDK：源码在 vendor/（来自官方 ios_cxr_l_sample，内网 spec 仓库外部不可达，故本地引用）。
# pod 命令用便携 Ruby：PATH=~/dev-ruby/portable-ruby/3.4.5/bin:~/dev-ruby/gems/bin GEM_HOME=~/dev-ruby/gems
platform :ios, '17.0'
source 'https://cdn.cocoapods.org/'

target 'EyeGuide' do
  use_frameworks!
  pod 'RGCoreKit', :path => 'vendor/RGCoreKit'
  pod 'RGCxrClient', :path => 'vendor/RGCxr'
end

# RGCoreKit podspec 写的 iOS 13，和新版 CocoaLumberjack（要 15+）冲突，统一拉到 17
post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
