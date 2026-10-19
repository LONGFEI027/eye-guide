# RGCxrClient 集成文档

RGCxrClient 是 Rokid AR 眼镜配套的 CXR 客户端协议，通过蓝牙与眼镜通信，提供鉴权、自定义 View、音频采集/播放、拍照、第三方应用管理等功能。

本文档以 **CXRClientDemo** 为参考，说明如何在工程中集成 RGCxrClient。

---

## 环境要求

- **iOS**: 13.0+（Podfile 建议 `platform :ios, '13.0'`）
- **Swift**: 5.0+
- **Xcode**: 建议 14.0+
- **依赖**: CocoaPods

---

## 一、工程配置

### 1.1 CocoaPods 依赖

在 `Podfile` 中为目标添加 RGCxrClient 及依赖：

```ruby
target 'YourApp' do
  project 'YourApp.xcodeproj'
  use_frameworks!
  
  # RGCxrClient 依赖 RGCoreKit
  pod 'RGCxrClient'
end
```

执行 `pod install` 后，使用 `.xcworkspace` 打开工程。

---

### 1.2 Info.plist 配置

参考 CXRClientDemo 的 Info.plist，需配置以下项：

#### URL Scheme（鉴权回调）

RGCxrClient 鉴权通过 Rokid AI 应用回调，需注册 `cxrl` scheme 接收回调：

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLName</key>
        <string>com.rokid.YourApp</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>cxrl</string>
        </array>
    </dict>
</array>
```

> 将 `CFBundleURLName` 中的 `com.rokid.YourApp` 替换为你的 Bundle ID。

#### 查询/拉起 Rokid AI 应用

发起鉴权时会拉起 Rokid AI 应用，需在 `LSApplicationQueriesSchemes` 中声明 `rokidai`：

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>rokidai</string>
</array>
```

#### 蓝牙后台模式

RGCxrClient 使用 CoreBluetooth 连接眼镜，需启用蓝牙 Central 后台模式：

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

#### 蓝牙权限说明（可选但推荐）

在 Info.plist 或 Build Settings 中配置 `NSBluetoothAlwaysUsageDescription`，用于向用户说明蓝牙用途：

| Key | 说明 | 示例 |
|-----|------|------|
| `NSBluetoothAlwaysUsageDescription` | 蓝牙使用说明（iOS 13+） | `"App 需要使用蓝牙来连接眼镜"` |

---

### 1.3 Scene 配置（iOS 13+）

若使用 SceneDelegate，需在 Info.plist 中配置 Scene Manifest，以便正确处理 URL 打开：

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
    <key>UISceneConfigurations</key>
    <dict>
        <key>UIWindowSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>Default Configuration</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
                <key>UISceneStoryboardFile</key>
                <string>Main</string>
            </dict>
        </array>
    </dict>
</dict>
```

---

## 二、代码集成

### 2.1 URL 处理（鉴权回调 / Deep Link）

鉴权完成后，Rokid AI 会通过 `cxrl://auth/callback?...` 回调到你的应用，必须正确转发 URL 给 RGCxrClient。新接口建议创建一个 `RGCxrLink` 并统一转发给它；旧接口仍可继续使用 `CxrClient.shared.handleOpenURL(_:)`。

#### AppDelegate（兼容 iOS 13 以下）

```swift
import UIKit
import RGCxrClient

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    private let link = CxrClient.makeLink(appDisplayName: "YourApp")

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if link.handleOpenURL(url) {
            return true
        }
        return false
    }
}
```

#### SceneDelegate（iOS 13+）

```swift
import UIKit
import RGCxrClient

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private let link = CxrClient.makeLink(appDisplayName: "YourApp")

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let urlContext = connectionOptions.urlContexts.first {
            handleURL(urlContext.url)
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let urlContext = URLContexts.first else { return }
        handleURL(urlContext.url)
    }
    
    private func handleURL(_ url: URL) {
        _ = link.handleOpenURL(url)
    }
}
```

> 同时保留 AppDelegate 的 `application(_:open:options:)`，部分场景仍会走此入口。

---

### 2.2 推荐使用：Link + Typed Session

新接入方建议使用 `RGCxrLink` 作为总入口。Link 负责鉴权、URL 回调、BLE 通道状态监听与创建 session；鉴权成功后 SDK 会根据回调中的设备名自动准备 BLE 通道，不需要调用 Android 风格的 `connect(token:)`。

```swift
import RGCxrClient
import Combine

final class YourController {
    private let link = CxrClient.makeLink(appDisplayName: "Example")
    private lazy var customAppSession = link.makeCustomAppSession(packageName: "com.example.glassapp")
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        link.events.authStatePublisher
            .sink { state in
                // 监听鉴权状态
            }
            .store(in: &cancellables)

        link.events.connectionStatePublisher
            .sink { connected in
                // 监听 BLE 通道状态
            }
            .store(in: &cancellables)

        customAppSession.deviceEvents.deviceInfoPublisher
            .sink { deviceInfo in
                // 监听设备信息
            }
            .store(in: &cancellables)

        customAppSession.mediaEvents.audioPublisher
            .sink { event in
                // 监听音频开始和音频数据流
            }
            .store(in: &cancellables)

        customAppSession.appEvents.resumePublisher
            .sink { resumed in
                // 监听目标眼镜 App 是否 resume
            }
            .store(in: &cancellables)

        customAppSession.commandEvents.notifyPublisher
            .sink { event in
                // 监听自定义 notify
            }
            .store(in: &cancellables)
    }

    func authenticate() {
        link.authenticate(scopes: [.microphone, .camera]) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                print(error)
            }
        }
    }

    func startGlassApp() {
        customAppSession.app.start(
            activityName: "com.example.glassapp.MainActivity",
            interruptAiWake: true
        ) { success in
            // 处理本次打开结果
        }
    }

    func updateDeviceControls() {
        customAppSession.device.setBrightness(level: 8) { success in
            // 处理亮度设置结果
        }
        customAppSession.device.getBrightness { level in
            // level 为 0...15
        }
        customAppSession.device.setVolume(level: 8) { success in
            // 处理媒体音量设置结果
        }
        customAppSession.device.getVolume { level in
            // level 为 0...15
        }
    }
}
```

CustomView 接入示例：

```swift
final class YourCustomViewController {
    private let link = CxrClient.makeLink(appDisplayName: "Example")
    private lazy var session = link.makeCustomViewSession()
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        session.customViewEvents.lifecyclePublisher
            .sink { event in
                // opened / updated / closed / iconsSent / error
            }
            .store(in: &cancellables)
    }

    func openView(viewData: String) {
        session.customView.open(viewData) { success, errorCode in
            // 处理本次打开结果
        }
    }
}
```

一次性操作结果通过 callback 返回；持续状态和通知通过 Publisher 订阅。

### 2.3 兼容使用：RGCxrClient

```swift
import RGCxrClient
import Combine

class YourViewController: UIViewController {
    private let client: RGCxrClient = CxrClient.shared
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        bindEvents()
    }

    private func bindEvents() {
        // 鉴权事件
        client.auth.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateUI(state: state)
            }
            .store(in: &cancellables)

        // 音频事件
        client.audioEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { event in
                switch event {
                case .started(let info): break // 音频开始
                case .stream(let packet): break // 音频数据流
                }
            }
            .store(in: &cancellables)
    }

    private func startAuth() {
        client.auth.authenticate(scopes: [.microphone, .camera]) { result in
            switch result {
            case .success: break
            case .failure(let error): print(error)
            }
        }
    }
}
```

---

## 三、API 参考

### 3.1 实例获取

```swift
let client: RGCxrClient = CxrClient.shared
let link: RGCxrLink = CxrClient.makeLink(appDisplayName: "Example")
let customViewSession = link.makeCustomViewSession()
let customAppSession = link.makeCustomAppSession(packageName: "com.example.glassapp")
```

### 3.2 RGCxrLink

| 成员 | 说明 |
|------|------|
| `events.authStatePublisher` | 鉴权状态流 |
| `events.authEventPublisher` | 鉴权事件流 |
| `events.connectionStatePublisher` | BLE 通道状态流 |
| `authenticate(scopes:completion:)` | 发起 scheme 鉴权；鉴权成功后 SDK 自动准备 BLE 通道 |
| `handleOpenURL(_:)` | 处理鉴权 URL 回调 |
| `disconnect()` | 手动断开 BLE 通道 |
| `makeCustomViewSession()` | 创建 CustomView session |
| `makeCustomAppSession(packageName:)` | 创建 CustomApp session |

### 3.3 RGCxrSession

基础 session 包含 CustomView / CustomApp 都能使用的能力：

| 成员 | 说明 |
|------|------|
| `device.getGlassDeviceInfo(callback:)` | 获取设备信息 |
| `device.isWearingCheckOn(callback:)` | 获取佩戴检测开关 |
| `device.setBrightness(level:callback:)` | 设置眼镜亮度，`level` 范围为 0...15；需会话处于可控制状态 |
| `device.getBrightness(callback:)` | 查询眼镜亮度 |
| `device.setVolume(level:callback:)` | 设置眼镜音量，`level` 范围为 0...15 |
| `device.getVolume(callback:)` | 查询眼镜音量 |
| `deviceEvents.deviceInfoPublisher` | 设备信息通知 |
| `deviceEvents.wearingStatusPublisher` | 佩戴状态通知 |
| `media.startAudioStream(codec:mode:)` / `media.stopAudioStream()` | 开启/关闭眼镜音频采集 |
| `media.startPlayAudio(codec:)` / `media.stopPlayAudio()` | 开始/停止眼镜音频播放 |
| `media.feedAudio(_:)` | 推送音频数据 |
| `media.takePhoto()` | 拍照并存相册 |
| `media.takePhoto(width:height:quality:callback:)` | 拍照并返回数据 |
| `media.changeAudioSceneId(_:callback:)` | 切换拾音模式 |
| `mediaEvents.audioPublisher` | 音频事件流 |
| `mediaEvents.imagePublisher` | 图像数据事件流 |
| `ai.setInterruptAiWake(_:callback:)` | 设置是否拦截 AI 语音唤醒 |
| `ai.sendExitAI(playSound:callback:)` | iOS 底层暂未提供对等协议，当前会回调失败 |
| `aiEvents.aiWakeInterruptPublisher` | AI 唤醒拦截状态通知 |
| `aiEvents.aiAssistPublisher` | AI 助手开始/停止事件；当前等待底层协议补齐 |

### 3.4 RGCxrCustomViewSession

| 成员 | 说明 |
|------|------|
| `customView.setIcons(_:callback:)` | 发送自定义 View 图标 |
| `customView.open(_:callback:)` | 打开自定义 View |
| `customView.update(_:callback:)` | 更新自定义 View |
| `customView.close(callback:)` | 关闭自定义 View |
| `customViewEvents.lifecyclePublisher` | 自定义 View 生命周期事件 |

### 3.5 RGCxrCustomAppSession

| 成员 | 说明 |
|------|------|
| `app.uploadAndInstall(path:callback:)` | 上传并安装眼镜 App |
| `app.uninstall(callback:)` | 卸载眼镜 App |
| `app.start(activityName:interruptAiWake:callback:)` | 启动眼镜 App，可同时设置 AI 唤醒拦截 |
| `app.stop(callback:)` | 停止眼镜 App |
| `app.isInstalled(callback:)` | 查询眼镜 App 是否已安装 |
| `appEvents.resumePublisher` | 目标眼镜 App resume 状态 |
| `commands.setNotifyEventListenCmds(_:)` | 设置可透出的 notify cmd 白名单 |
| `commands.send(cmd:payload:callback:)` | 发送自定义命令 |
| `commands.send(cmd:payload:stream:callback:)` | 发送自定义命令和大二进制数据 |
| `commandEvents.notifyPublisher` | 自定义 notify 事件流 |

### 3.6 旧 RGCxrClient 属性

| 属性 | 类型 | 说明 |
|-----|------|------|
| `auth` | RGCxrClientAuthManager | 鉴权管理器 |
| `audioEventPublisher` | AnyPublisher\<RGCxrClientAudioEvent, Never\> | 音频事件流 |
| `customViewRunningEventPublisher` | AnyPublisher\<RGCxrClientCustomViewRunningEvent, Never\> | 自定义 View 运行状态 |
| `appResumeChangeEventPublisher` | AnyPublisher\<RGCxrClientAppResumeChangeEvent, Never\> | 眼镜端三方应用 resume 状态 |

### 3.7 旧 RGCxrClient 主要方法

| 方法 | 说明 |
|------|------|
| `handleOpenURL(_:)` | 处理 URL（鉴权回调、Deep Link） |
| `sendCustomViewIcons(_:callback:)` | 发送自定义 View 图标；大 JSON 经本地 TCP 上传，约 30 秒内无成功回包则 `false` |
| `openCustomView(_:callback:)` | 打开自定义 View（大文本走 TCP）；`callback(success, errorCode)`，`errorCode=-1` 表示 OTA/Phone 进行中；超时或 TCP 失败时 `success=false`/`errorCode=nil` |
| `updateCustomView(_:callback:)` | 更新自定义 View（大文本走 TCP），约 30 秒超时 |
| `closeCustomView(_:callback:)` | 关闭自定义 View（仍走 BLE，约 5 秒超时） |
| `startRecord(_:codec:mode:)` / `stopRecord(_:)` | 开启/关闭眼镜音频采集 |
| `startPlayAudio(codec:)` / `stopPlayAudio()` | 开始/停止播放音频 |
| `feedAudio(_:)` | 推送音频数据到眼镜播放 |
| `takePhoto(width:height:quality:)` | 拍照存相册 |
| `takePhotoWithData(width:height:quality:callback:)` | 拍照返回数据 |
| `setBrightness(level:callback:)` / `getBrightness(callback:)` | 设置/查询眼镜亮度 |
| `setVolume(level:callback:)` / `getVolume(callback:)` | 设置/查询眼镜音量 |
| `queryApp(callback:)` | 查询应用是否安装 |
| `openApp(activityName:url:callback:)` | 打开眼镜应用 |
| `stopApp(callback:)` | 停止应用 |
| `uninstallApp(callback:)` | 卸载应用 |
| `installApp(_:callback:)` | 安装应用 |

### 3.8 常用枚举

**RGCxrAudioCodec**: `pcm` / `oggOpus` / `mp3`  
**RGCxrAudioMode**: `xf` / `antClose` / `rokidOmni` / `antOmni` / `xfOrientation` / `barrierFree`

---

## 四、RGCxrClientAuthManager

鉴权管理器，用于发起鉴权、处理回调、管理 Token。

| 方法 | 说明 |
|------|------|
| `authenticate(scopes:bundleId:appName:completion:)` | 发起鉴权（会拉起 Rokid AI） |
| `handleCallback(url:)` | 处理回调（由 `handleOpenURL` 内部调用） |
| `isAuthenticated()` | 是否有有效 Token |
| `getCurrentToken()` / `getCurrentSessionId()` / `getCurrentDeviceName()` | 获取当前鉴权信息 |
| `clearAuthentication()` | 清除鉴权信息 |

| 属性 | 说明 |
|------|------|
| `config` | RGCxrClientAuthConfig，可配置 server/callback scheme、host、path |
| `statePublisher` | 鉴权状态流 |
| `eventPublisher` | 鉴权事件流 |

---

## 五、参考示例

完整可运行示例见 **CXRClientDemo**：

- 工程路径：`CXRClientDemo/CXRClientDemo.xcodeproj`
- Podfile：需将 CXRClientDemo 加入 workspace 并执行 `pod install`
- 运行：选择 CXRClientDemo scheme，连接真机运行（蓝牙需真机）

CXRClientDemo 包含：

- 鉴权流程（发起、清除、状态监听）
- 音频采集/播放（startRecord、feedAudio、takePhoto 等）
- 拍照（takePhoto、takePhotoWithData）
- 第三方应用管理（queryApp、openApp、stopApp、installApp、uninstallApp）
- 事件订阅（auth、audio、customViewRunning）

---

## 六、注意事项

1. **真机调试**：蓝牙功能需在真机上测试，模拟器无法连接眼镜。
2. **Rokid AI 应用**：鉴权需安装 Rokid AI 应用，`authenticate` 会通过 `rokidai://` 拉起。
3. **URL Scheme 一致性**：`RGCxrClientAuthConfig` 中 `callbackScheme` 默认 `cxrl`，需与 Info.plist 中 `CFBundleURLSchemes` 一致。
4. **闭包捕获**：订阅 Publisher 时使用 `[weak self]`，避免循环引用。
