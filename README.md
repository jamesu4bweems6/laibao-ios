# 来宝接龙 iOS 原生客户端（LaiBao iOS）

纯 SwiftUI 原生开发的「来宝接龙」iOS 客户端，面向 **iOS 26 / iOS 27 原生 Liquid Glass（液态玻璃）** 设计语言打造。

- **零第三方依赖**：仅使用 Apple 原生框架（`SwiftUI`、`MapKit`、`CoreLocation`、`Security`、`CoreImage`、`UserNotifications`、`BackgroundTasks`、`Foundation`）。
- **纯本地单用户直达**：无需部署外部后端服务器，也无需繁琐的本地管理员密码门禁，打开即直达 5 标签 Liquid Glass 工作区；App 直接通过 HTTPS 与来宝接龙官方接口通信，配置、常用点位与提醒计划保存在本机沙盒，会话令牌受 iOS Keychain 加密保护。
- **开箱即打包未签名 IPA**：内置 deterministic `LaiBao.xcodeproj`、XcodeGen `project.yml`、一键未签名打包脚本与 GitHub Actions 自动构建工作流。

---

## iOS 26 / iOS 27 原生 Liquid Glass 设计

本应用严格遵循 Apple iOS 26 / iOS 27 Liquid Glass 设计规范，**不设置 `UIDesignRequiresCompatibility`**，默认启用系统级原生液态玻璃渲染与动态折射：

- **原生 Glass API**：采用 `.glassEffect(...)`、`GlassEffectContainer`、`.glassEffectID(...)`、`.buttonStyle(.glass)` 与 `.buttonStyle(.glassProminent)` 构建悬浮工具栏、地图控制簇、分段选择与底部提交栏。
- **自适应导航与沉浸滚动**：采用 `.tabViewStyle(.sidebarAdaptable)` 与 `.tabBarMinimizeBehavior(.onScrollDown)`，在 iPhone 与 iPad 上自动切换悬浮底栏 / 侧边栏，滚动时自动收起底栏释放阅读视野。
- **窗口焦点感知**：结合 `@Environment(\.appearsActive)` 在应用切入非活动状态或分屏失焦时平滑调整玻璃层次与高亮反馈。
- **Four-Layer Rule（四层透明法则）**：不在页面底层堆叠破坏折射的硬编码不透明纯色遮罩，保持内容层、玻璃控件层、高亮聚焦层与系统导航栏之间的自然通透感。

---

## 核心功能一览

1. **开箱直达与 iOS Keychain 令牌保护**
   - 单用户本地工作区，启动即直接进入「账号 / 填报 / 记录 / 提醒 / 点位」5 标签原生界面。
   - 来宝接龙 Bearer Token 按 `accountName` 仅加密存储在系统 **Keychain**（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），绝不落盘明文 JSON。
   - 网络层强制 HTTPS 校验并拦截协议降级，运行日志自动脱敏 `Bearer` / `Authorization` 凭据。

2. **多方式登录来宝账号**
   - **公众号扫码登录**：原生 `CoreImage` 生成二维码并自动轮询扫码状态。
   - **手动 Token 导入**：安全输入框自动去除 `Bearer ` 前缀并直存 Keychain。
   - **微信 `code` 登录**：调用 `/v4/login` 完成授权。
   - 支持多账号切换、`whoami` 校验与服务端 `epochMillis` 时间校准（`Cache-Control: no-store`）。

3. **我的接龙与短链智能解析**
   - 三视角接龙列表：**我参与的**（`/v1/participation_forms`）、**我创建的**（`/v2/creation_forms`）、**我管理的**（`/v3/manager_forms`），支持关键词搜索与分页加载。
   - 剪贴板一键识别并解析原始 Form ID、各品牌域名链接（`qun100.com` / `qun100.net`）、`launchApp?address=...`、`#小程序://` 提示以及 `s.qun100.com/link/*` 短链（严格白名单 HTTPS 443 302 跳转并防路径穿越 / SSRF）。

4. **全类型动态表单填报与 MapKit 地图选点**
   - 动态解析并渲染来宝接龙全部主流字段类型：`LOCATION`（支持当前位置 / `SPECIFIED_LOCATION` 围栏锚点 / 自由选点）、`WORD`、`RADIO`/`RADIO_V2`、`CHECKBOX`/`CHECKBOX_V2`/`CHOICE`、`DATE`（`YYYY-MM-DD HH:mm`）、`AREA`、`MULTI_LEVEL_SELECT`、`IMAGE`（附带 `imageDetails`）及数字/手机号/身份证/邮箱/网址/银行卡等校验字段。
   - 内置原生 SwiftUI **`MapKit` 地图选点器**：支持点选落针、`MKLocalSearch` 地点检索、`CLGeocoder` 逆地理反查、GCJ-02 ↔ WGS-84 双向坐标转换、围栏圆圈实时距离判定与随机微调抖动（jitter）预览。
   - 支持 **Dry-Run 载荷预览**、补卡（Patch）与已有记录编辑模式（自动剥离 `patch*` 字段并兼容 HTTP 204）。

5. **提交记录与一键带入编辑**
   - 支持查询**我的提交记录**（兼容 `/v1/{formId}/form_data/owner`、`/v3/{formId}/form_data` 与业务码 `13362`）、**最近一条记录**与**全员列表**。
   - 支持点击任意历史记录一键带入填报页进行修改重提。

6. **定时提醒与 POI 常用点位池**
   - 本地多时段 / 按星期循环打卡计划，联动 `UNUserNotificationCenter` 本地通知提醒与一键立即打卡，并支持可选 `BGAppRefreshTask`（`com.laibao.ios.reminder.refresh`）后台刷新。
   - 常用打卡点位（POI）池管理 + GCJ-02 / WGS-84 坐标转换与距离测算小工具。

---

## 目录结构

```text
laibao-ios/
├── LaiBao.xcodeproj/              # 已预生成的确定性 Xcode 工程（无签名配置）
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/LaiBao.xcscheme
├── project.yml                    # XcodeGen 工程描述文件（可用 xcodegen 重新生成）
├── Resources/
│   ├── Info.plist                 # 应用元数据与权限声明（不含 UIDesignRequiresCompatibility）
│   └── Assets.xcassets/           # AccentColor 与 1024×1024 Light/Dark/Tinted AppIcon
├── Sources/
│   ├── App/                       # App 入口、全局状态与 Liquid Glass 主壳
│   ├── Core/                      # 纯 Swift 6 协议客户端、Keychain、地理算法、本地存储与调度
│   └── Views/                     # 账号、填报、地图选点、记录、提醒、POI 与 Liquid Glass 组件
├── Tests/
│   └── LaiBaoTests/               # 离线 XCTest 单元测试套件
├── scripts/
│   └── build-unsigned-ipa.sh      # macOS 一键构建未签名 .ipa 脚本
└── .github/workflows/
    └── build-unsigned-ipa.yml     # GitHub Actions 自动测试与打包未签名 .ipa 工作流
```

---

## 构建未签名 `.ipa`

### 方式一：在 macOS 上本地打包

环境要求：macOS + **Xcode 26 或更新版本**（支持 iOS 26.0+ SDK 与 Swift 6）。

```bash
cd laibao-ios
bash scripts/build-unsigned-ipa.sh
```

脚本会自动执行以下操作：
1. 调用 `xcodebuild` 以 `Release` 配置和 `-sdk iphoneos` 构建，彻底关闭所有代码签名参数（`CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、`CODE_SIGN_IDENTITY=""` 等）。
2. 将生成的 `LaiBao.app` 组装至 `Payload/LaiBao.app`，并清除任何残留的 `_CodeSignature`、`embedded.mobileprovision` 或 `SC_Info`。
3. 打包生成 `dist/LaiBao-unsigned.ipa`，同时输出 SHA-256 校验值与 `unzip -l` 目录清单。

常用可选参数：
- `bash scripts/build-unsigned-ipa.sh --regenerate-project`：构建前先通过 `xcodegen generate` 重新生成 `LaiBao.xcodeproj`（需先 `brew install xcodegen`）。
- `bash scripts/build-unsigned-ipa.sh --clean`：清理缓存后全量构建。
- `bash scripts/build-unsigned-ipa.sh --output /tmp/LaiBao.ipa`：指定输出路径。

### 方式二：无 Mac 环境通过 GitHub Actions 云端构建

仓库内已提供 `.github/workflows/build-unsigned-ipa.yml`（默认使用 `macos-26` Runner）：

1. 将仓库推送至 GitHub（注意：若本目录位于子目录 `laibao-ios/`，需将 `.github/workflows/build-unsigned-ipa.yml` 置于仓库根目录 `.github/workflows/` 下方可被 GitHub Actions 自动识别）。
2. 在 GitHub 仓库的 **Actions → Build Unsigned iOS IPA (LaiBao)** 页面点击 **Run workflow** 手动触发，或推送 `laibao-ios/**` 变更自动触发。
3. 工作流会先在 iOS Simulator 上运行 `LaiBaoTests` 单元测试，再执行 `bash scripts/build-unsigned-ipa.sh` 并校验产物无签名残留。
4. 构建完成后，在本次 Workflow Run 底部的 **Artifacts** 中下载 `LaiBao-unsigned-ipa`（内含 `LaiBao-unsigned.ipa`）。

---

## 未签名 `.ipa` 安装方式

构建产出的 `LaiBao-unsigned.ipa` 不包含签名信息，可根据设备环境选择以下任一方式安装：

- **TrollStore（巨魔商店）**：在支持的设备与系统版本上，直接将 `LaiBao-unsigned.ipa` 分享导入 TrollStore 即可永久免签安装。
- **AltStore / SideStore**：在 iPhone 上通过 AltStore 或 SideStore 导入 `LaiBao-unsigned.ipa`，使用个人 Apple ID 自动重签安装（免费账号需每 7 天续签一次）。
- **Sideloadly / 爱思助手 / 轻松签（ESign）**：在电脑端或手机端导入未签名 `.ipa`，选择个人开发者证书、免费 Apple ID 或自备证书进行重签安装。
- **Xcode 直接真机安装**：用 Xcode 打开 `LaiBao.xcodeproj`，在 `Signing & Capabilities` 中临时选择你的个人 Team 并勾选自动签名，即可直连真机运行调试。

> **权限说明**：
> - `NSLocationWhenInUseUsageDescription`：用于在地图选点时定位当前位置并校验打卡围栏距离。
> - `UIBackgroundModes: fetch` 与 `BGTaskSchedulerPermittedIdentifiers`：仅用于可选的本地定时提醒后台刷新；受 iOS 沙盒机制限制，定时任务仍以本地通知提醒 + 一键打卡为主。
