# 小路 EyeGuide

视障用户的随身视觉助手（原型）：手机后置摄像头 + 百炼实时多模态模型，语音对话帮你"看"。

**定位（写进了人格，不可动摇）**：白手杖的智能补充，不是导盲设备。安全层（避障、台阶、车流）永远属于盲杖和用户自己的听觉；小路只做语义层——读牌、找东西、描述环境，并且不确定就直说不确定。

## 三个核心场景

| 场景 | 用法 | 背后 |
|---|---|---|
| 读字 | "这站牌写的什么" | `look_closely` 工具拍高清照片 → 服务器 /api/vision（qwen-vl）逐字读 |
| 找东西 | "帮我找个空座" | 每秒一帧实时画面，钟面方向引导（十二点=正前方） |
| 说环境 | "周围什么样" | 实时帧 + 粗定位（街区级），两三句说重点 |

## 技术管线（复用 photo-coach）

- 实时语音：`VoiceLink` → wss://feizhu.asia/realtime（qwen3.8-omni-flash-realtime，音色 Serena），server_vad + 客户端决定回复时机，AEC 回声消除、回声转写过滤、回复排队，全套照搬 photo-coach 已验证的实现
- 画面：`CameraManager` 每秒一帧 640px JPEG `input_image_buffer.append`（须先发音频）
- 工具（刻意只有三个）：`look_closely`（高清细看/OCR）、`set_zoom`（0.5/1/2/3）、`set_torch`（手电筒）
- 账号：feizhu.asia 登录 Cookie，用量同一账户

## 构建

```bash
xcodebuild -project EyeGuide.xcodeproj -scheme EyeGuide \
  -destination 'generic/platform=iOS Simulator' build
```

真机（iPhone zhu）：

```bash
xcodebuild -project EyeGuide.xcodeproj -scheme EyeGuide \
  -destination 'id=00008120-000C1D2E3E60201E' \
  DEVELOPMENT_TEAM=G8R46MT3M7 -allowProvisioningUpdates build
xcrun devicectl device install app --device DAD9E1A3 <DerivedData里的EyeGuide.app>
```

## 下一步（按验证优先级）

1. 真机跑通三场景，自己蒙眼先测
2. 找 2~3 位真实视障用户试用访谈（残联/盲协渠道）
3. 用户说有用再考虑：持续播报模式、骨传导耳机适配、胸前固定支架、本地深度/障碍提示（安全层，不走大模型）
