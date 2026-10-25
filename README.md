# 龙龙短剧 · ShortPlay

使用 Flutter 开发的多端短剧播放器，支持 Android 手机、Android TV、iOS 和 macOS。提供内容浏览、搜索联想、系列剧选季、滑动切集、弹幕、离线缓存与观看历史，并为电视遥控器提供独立适配。

[版本与下载](https://github.com/Erlmo/shortplay/releases) · [iOS TestFlight](https://testflight.apple.com/join/bZEAapYp) · [问题反馈](https://github.com/Erlmo/shortplay/issues)

## 平台支持

| 平台 | 当前支持情况 |
| --- | --- |
| Android 手机 | 原生播放器，提供 ARM 32 位和 64 位构建 |
| Android TV / 电视盒子 | 与手机版共用 APK，自动识别 TV，适配遥控器焦点与按键 |
| iOS | AVPlayer 原生播放，工程最低系统版本为 iOS 15.0 |
| macOS | AVPlayer 原生播放，工程最低系统版本为 macOS 10.15 |

当前仓库尚未提供 Windows、Web、Linux 或 HarmonyOS 原生版本。

## 主要功能

### 内容发现与搜索

- 首页、新剧，以及推荐、热播、收藏榜、热搜等栏目。
- 观看历史与“继续观看”，支持从本地记录恢复播放。
- 搜索联想、搜索历史，以及综合、漫剧、短剧等搜索范围。
- 具有关联季信息的系列剧可按季浏览，普通作品保持列表展示。
- 点击联想行进行搜索；具有可播放剧集信息的候选另提供直接播放入口。

### 观看反馈

新增观看记录上报，用于为首页推荐提供观看偏好参考，帮助发现更多可能感兴趣的短剧。

### 播放与选季

- 竖屏上下滑动切集，支持横屏播放、拖动进度、倍速、清晰度切换和定时停止。
- 选集面板支持集数选择与相关季查看。
- 相关季可用时，播完本季最后一集、继续上滑或在 TV 上向下切集，可以进入下一季。
- 提前加载下一季目录并预热首集；季信息加载失败时仍可播放本季。
- 竖屏启用裁切优化：整轴合计裁切比例超过 15% 时改为完整显示；横屏可切换完整显示与等比例铺满。

跨季连播用于在线剧场资源，离线播放不自动切到下一季。实际切集速度取决于设备、网络与预加载状态。

### 弹幕与离线缓存

- 弹幕随播放位置显示，支持拖动进度后的时间线同步。
- 支持滚动文字、表情弹幕与弹幕开关。
- 按集选择缓存，支持单集和整剧暂停、继续，以及整剧缓存删除。
- 已完成缓存的集数可直接离线播放，下载任务状态保存在本地。

### Android TV

- 首页、搜索、详情、选集和缓存页面支持方向键焦点导航。
- 搜索提供首字母键盘，联想行与系列剧各季可用遥控器选择。
- 在首页列表中按返回，先回到顶部栏目，便于切换新剧、热播等内容。
- 播放时支持上下切集、左右快进或快退 10 秒、确认键暂停或继续；菜单键或长按确认可打开播放设置。
- TV 显示二维码，手机扫码后在网页输入分享链接，再交给 TV 识别播放。

### 分享识别与更新

- 手机端通过主动粘贴分享链接识别剧集并播放。
- Android 32 位、Android 64 位和 iOS 支持检查更新。
- 支持可选更新和强制更新提示，由系统打开对应下载链接。

## 项目结构

首页、详情页和播放器已经按职责拆分，布局、播放流程与公共组件分别维护。

```text
lib/
├── main.dart                         # 应用入口、主题与生命周期
├── models/                           # 剧集、搜索结果、播放记录等模型
├── pages/
│   ├── home/                         # 首页栏目、列表、卡片与继续观看
│   ├── drama_detail_page/            # 详情页动作、手机与宽屏布局
│   ├── player_page/                  # 播放、控件、键盘、跨季与视图
│   ├── global_search_page.dart       # 搜索与联想
│   ├── cache_page.dart               # 缓存管理
│   └── settings_page.dart            # 应用设置
├── services/                         # 播放、缓存、弹幕与本地记录
└── widgets/                          # 播放控件、弹幕、系列卡与 TV 组件

android/                              # Kotlin / Media3 / JNI
ios/                                  # Swift / AVPlayer / 原生预编译库
macos/                                # Swift / AVPlayer
test/                                 # 单元与小部件测试
```

Flutter 通过 MethodChannel 和 EventChannel 与原生播放器通信。Android 使用 Media3 ExoPlayer，iOS 与 macOS 使用 AVPlayer；播放与预热由平台桥接和原生库配合完成。

## 本地运行

### 环境与依赖

- Flutter SDK；Dart 版本需满足 `pubspec.yaml` 中的 `^3.6.2` 约束。
- Android：Android SDK 36，以及与工程兼容的 JDK、Gradle 和 NDK 环境。
- iOS / macOS：macOS 开发环境、Xcode 与 CocoaPods。
- Android 调试设备需为 `armeabi-v7a` 或 `arm64-v8a`；仓库未提供 x86 / x86_64 Android 原生库。

仓库已包含 Android `.so` 与 Apple `.xcframework` 预编译库，无需从未公开的原生源码重新构建。macOS 工程会复用 `ios/Frameworks` 中的 Apple 原生库。

```bash
git clone --branch release https://github.com/Erlmo/shortplay.git
cd shortplay
flutter pub get
flutter doctor
flutter devices
```

将下面的 `DEVICE_ID` 替换为 `flutter devices` 列出的设备 ID：

```bash
flutter run -d DEVICE_ID
```

## 构建发布包

### Android：32 位与 64 位 APK

```bash
flutter build apk --release \
  --target-platform android-arm,android-arm64 \
  --split-per-abi
```

输出目录：`build/app/outputs/flutter-apk/`。

| 文件 | 架构 |
| --- | --- |
| `app-armeabi-v7a-release.apk` | ARM 32 位 |
| `app-arm64-v8a-release.apk` | ARM 64 位 |

手机和 Android TV 使用对应架构的同一安装包。正式发布时需配置自己的 Android 发布签名；当前工程的 release 构建仍使用 debug 签名配置。

### iOS：IPA

```bash
flutter build ipa --release
```

构建前在 Xcode 中配置 Team、证书与描述文件。Archive 输出在 `build/ios/archive/`，成功导出的 IPA 在 `build/ios/ipa/`。

### macOS

```bash
flutter build macos --release
```

应用输出在 `build/macos/Build/Products/Release/`，签名、归档与分发按自己的发布配置处理。

### 版本号

当前 Android 版本名为 **3.2.3**，在 `android/app/build.gradle` 中独立设置；iOS 使用 `pubspec.yaml` 中的 **3.2.0+17**。构建号可通过 `--build-number` 指定，发布前同时核对工程配置和实际产物。

## 开发与反馈

```bash
flutter pub get
dart format --set-exit-if-changed lib test
flutter analyze
flutter test -r compact
```

提交问题时，请附上平台与系统版本、APP 版本、是否为 TV、相关剧名或集数，以及复现步骤。播放或缓存问题还可以补充发生时的位置与错误提示。

## 源码与原生库

本仓库提供 Flutter 客户端、平台桥接和原生预编译库；原生核心源码不公开。

本地 `docs/` 与构建目录不上传 GitHub，公开使用说明集中在本 README。
