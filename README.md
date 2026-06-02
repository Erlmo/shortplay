# ShortPlay

Flutter 短剧播放器，**核心做两件事：原生 DRM 解密 + 像红果短剧一样丝滑的滑动体验**。

> 本项目仅用于学习和技术交流，不提供任何内容资源。使用时请确保拥有相关接口和内容的合法授权。
> 涉及到的所有算法不开源（六神，spade_a）。

## 一、原生 DRM 解密

短剧 CDN 下发的是标准 MP4 CENC（AES-128 CTR）加密视频。本项目用纯 C 实现解密核心，**Android/iOS 共用一套代码**，零第三方依赖：

- `aes.c`：AES-128 软实现（不上 OpenSSL/CommonCrypto）
- `mp4_cenc.c`：解析 moov / saiz / saio / senc，构建采样表
- `crypto_stream.c`：生产者线程持续 HTTP Range 拉数据，消费者按播放器 read 节奏吐明文，**全程零落盘**

播放器层接入方式（双端对称）：

| 平台 | 播放器 | 接入点 |
|------|--------|--------|
| Android | Media3 ExoPlayer | 自定义 `CryptoDataSource extends BaseDataSource` |
| iOS | AVPlayer | `AVAssetResourceLoaderDelegate` |

C 层暴露统一 ABI，播放器无关：

```c
void*   sp_stream_open(const char* cdn_url, const char* key_hex);
int64_t sp_stream_read(void* handle, char* buf, uint64_t nbytes);
int64_t sp_stream_seek(void* handle, int64_t offset);
int64_t sp_stream_size(void* handle);
void    sp_stream_close(void* handle);
```

播放器拿到的就是已解密的明文 MP4 字节，硬解链路完全不变。

## 二、红果级丝滑滑动

短剧 App 的核心体验是「上下滑切集毫无停顿」，这点远比清晰度重要。本项目用两个机制做到这一点：

### 1. 3-Player 滑动窗口

播放页同时维护最多 3 个原生播放器实例：

- 当前集（playing）
- 下一集（已 create + prepare，静音等待 firstFrame）
- 上一集（保留最后一帧 + 进度，回切瞬时）

用户上滑时**直接交换引用**，不再走 create→open→prepare→firstFrame 链路。切集首帧从 ~600ms 降到 ~100ms 量级。

### 2. 分级 prewarm

`crypto_core` 暴露三档预热粒度：

| 接口 | 内容 | 用途 |
|------|------|------|
| `sp_prewarm` | 解析 moov + 抓 128KB mdat seed | N+1 全量，立即可播 |
| `sp_prewarm_header_only` | 仅解析 moov | N+2/N+3 节省带宽 |
| `sp_prewarm_seed_mdat` | 升级 header-only 加 mdat | 接近播放时再补 |

调度策略：
- 当前集开播 → 立刻全量预热 N+1
- 5s 后 → header-only 预热 N+2
- 10s 后 → header-only 预热 N+3
- 滑到 N+1 时 → 把 N+2 升级成 mdat seed

用户最终滑到的那一集大概率已经预热完毕，没滑到的不浪费带宽。

## 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                     Flutter (Dart) 层                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │  Pages   │  │ Widgets  │  │ Services │  │  Models  │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────────┘    │
│       └──────┬──────┴──────┬──────┘                         │
│              │             │                                 │
│        MethodChannel  EventChannel                          │
└──────────────┼─────────────┼─────────────────────────────────┘
               │             │
       ┌───────┴─────────────┴────────┐
       │                              │
┌──────▼──────────┐         ┌─────────▼────────┐
│ Android (Kotlin) │         │   iOS (Swift)    │
│ NativePlayer-    │         │ NativePlayer-    │
│ Plugin.kt        │         │ Plugin.swift     │
│ ┌──────────────┐ │         │ ┌──────────────┐ │
│ │  ExoPlayer   │ │         │ │   AVPlayer   │ │
│ │ +CryptoData- │ │         │ │ +Resource-   │ │
│ │  Source      │ │         │ │  Loader      │ │
│ └──────┬───────┘ │         │ └──────┬───────┘ │
└────────┼─────────┘         └────────┼─────────┘
         │  JNI                       │  C-bridge
┌────────▼────────────────────────────▼─────────┐
│       Native C Crypto Core (libshortplay_     │
│       crypto.so / ShortplayCrypto.xcframework)│
│  ┌──────────┐ ┌──────────┐ ┌──────────────┐  │
│  │  aes.c   │ │mp4_cenc.c│ │crypto_stream │  │
│  │  AES-CTR │ │ CENC 解析│ │  生产者-消费者│  │
│  └──────────┘ └──────────┘ └──────┬───────┘  │
└────────────────────────────────────┼──────────┘
                                     │
                                ┌────▼─────┐
                                │  CDN     │
                                │ (HTTP    │
                                │  Range)  │
                                └──────────┘
```

## 技术栈

- Flutter 3.24+ / Dart 3.6+
- Android：Kotlin + Media3 ExoPlayer 1.4.1 + JNI
- iOS：Swift + AVFoundation + ResourceLoader
- Native：纯 C，无第三方依赖

## 快速开始

```bash
git clone <repo-url>
cd shortplay
flutter pub get
flutter run
```

前置要求：Flutter 3.24+、Android NDK、Xcode 15+，真机调试推荐。

## License

MIT
