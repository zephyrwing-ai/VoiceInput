# VoiceInput（macOS 语音输入框架）

在任意应用中按住 **Fn + Control** 说话，松开结束。语音由云端模型识别（默认 OpenRouter 上的 `openai/whisper-large-v3-turbo`），经过规则清理和可选的模型润色后，写进当前光标所在的输入框。

这是一个可以运行的框架版本：主流程已经接通，各模块按设计文档拆分，方便后续逐个替换和优化。

## 构建与运行

需要 macOS 14 及以上、Xcode 16 及以上（当前在 macOS 26.5 + Xcode 26.6 + Swift 6.3 上验证）。

```bash
cd VoiceInput
swift test                      # 单元测试（组合键、规则清理、分段、WAV、润色判断）
./scripts/build_app.sh          # 打包成 build/VoiceInput.app（ad-hoc 签名）
OPEN=1 ./scripts/build_app.sh   # 打包并启动
```

开发时也可以直接用 Xcode 打开 `Package.swift` 编辑代码。但麦克风权限要求 App 带有 Info.plist，所以运行时请使用脚本打出来的 `.app`。

### 签名与权限（重要）

ad-hoc 签名的 App 每次重新编译后签名都会变，系统会认为它是一个新的 App，之前授予的"辅助功能"权限会失效。建议创建一个固定的自签名证书：

1. 打开"钥匙串访问" → 菜单"证书助理" → "创建证书…"；
2. 名称填 `VoiceInput Dev`，身份类型选"自签名根证书"，证书类型选"代码签名"；
3. 之后用这个证书打包：`SIGN_IDENTITY="VoiceInput Dev" ./scripts/build_app.sh`。

如果需要重新测试授权流程，可以重置权限：

```bash
tccutil reset Accessibility com.manus.voiceinput
tccutil reset Microphone com.manus.voiceinput
```

## 配置模型

App 一启动就会主动申请权限：先弹出系统的麦克风授权框，答复后再弹出辅助功能提示并打开对应的系统设置页，授权后自动生效，不需要重启。麦克风之前被拒绝过时（系统不会再弹框），会自动打开麦克风设置页。如果权限还没给全或者没有填写 API Key，同时会打开设置窗口。之后也可以从菜单栏图标进入"设置…"。

| 页签 | 内容 |
|---|---|
| 模型服务 | 语音识别模型列表，可以添加多个并选择当前使用哪一个。每个配置只需要填写名称、Base URL、API Key 和模型 ID（可点"选择模型"从服务商拉取列表）。点"保存"时会在后台自动验证一次连接 |
| 输入 | 上屏方式（实时分段 / 松手后一次性）、繁转简、提示音、个人词典 |
| 权限 | 麦克风和辅助功能的状态与授权按钮 |

接口格式、超时、语言、零数据保留都由程序自动处理，用户不需要选择：Base URL 是 OpenRouter 时使用它的 JSON 接口，并优先只路由到零数据保留（ZDR）端点，所选模型没有这类端点时自动改用普通路由；其他服务一律使用 OpenAI 兼容的 multipart 接口。超时按录音长度自动计算（15～120 秒），语言自动检测。

| 接口格式 | 地址 | 适用 |
|---|---|---|
| OpenRouter 语音转写（JSON） | `{base}/audio/transcriptions`，base64 音频 | OpenRouter（默认） |
| OpenAI 兼容语音转写（multipart） | `{base}/audio/transcriptions`，上传文件 | OpenAI、Groq 等 |
| OpenAI 兼容对话 | `{base}/chat/completions` | 润色模型（OpenRouter 或任意兼容服务） |

API Key 存在系统钥匙串里，不写进配置文件。其他设置存在 UserDefaults 里（键名 `VoiceInput.Settings.v1`）。

## 处理流程

```
按下 Fn + Control
  → 记录当前焦点输入框（FocusInspector）：所属 App、类别、是否可编辑、是否密码框 / 搜索框
  → 开始录音（AudioRecorder，跟随系统默认输入设备，16kHz 单声道）
  → 刘海胶囊显示波纹；300ms 内没有收到音频时显示"麦克风准备中"
录音中（实时模式）
  → 按停顿切段（VoiceActivitySegmenter：停顿 550ms 或单段满 9 秒）
  → 每段发送到云端识别 → 规则清理 → 写进输入框（按顺序）
松开
  → 识别最后一段 → 能整段替换时调用润色模型 → 替换成润色后的版本 → 恢复剪贴板
  → 按住不到 0.3 秒视为误触；录音中按其他键会取消
```

搜索框，以及找不到可编辑输入框的情况，会自动改为"松手后一次性处理"。如果最终无法写入，会在刘海下方显示卡片，文字已复制到剪贴板。

## 目录结构

```
Sources/VoiceInput/
├─ App/VoiceInputApp.swift          入口、菜单栏图标
├─ Session/DictationController.swift 一次"按住说"的完整流程
├─ Hotkey/HotkeyMonitor.swift       CGEventTap + Fn/Control 组合键状态机
├─ Audio/AudioRecorder.swift        麦克风采集、重采样、音量电平
├─ Audio/AudioProcessing.swift      WAV 编码、按停顿分段
├─ Services/ModelServices.swift     语音识别 / 润色的 HTTP 客户端、测试连接
├─ Text/RuleCleaner.swift           语气词、重复、繁转简、Whisper 幻觉过滤、标点
├─ Text/Polishing.swift             是否调用模型、提示词、超时与忠实性保护
├─ Text/AppCategory.swift           App 分类表与对应风格
├─ Focus/FocusInspector.swift       焦点识别、AX 工具、Electron / Chrome 结构树开关
├─ Insertion/TextInserter.swift     AX 写入、粘贴、剪贴板备份与恢复、整段替换
├─ HUD/                             刘海胶囊（NSPanel + SwiftUI）
├─ Permissions/PermissionManager.swift
└─ Settings/                        模型配置、钥匙串、设置界面
```

## 已验证 / 待验证

已验证：工程能够编译和打包；16 个单元测试全部通过；App 可以启动并常驻菜单栏，没有崩溃。

以下内容需要在真机上授权并配置 API Key 后实测：

1. **快捷键**：外接键盘可能没有 Fn 键。另外，系统设置里"按下 🌐 键时"的行为（切换输入法、表情等）可能和组合键冲突。
2. **粘贴**：实时模式下，用户仍然按着 Fn + Control，这时程序发出的 ⌘V 只带 Command 标志，需要在各个应用中验证不会变成别的组合键。原生控件优先使用 AX 直接写入，不受这个问题影响。
3. **分段识别的准确率和延迟**：短段落缺少上下文，准确率可能低于整段识别；每一段都是一次 HTTP 请求，需要测量从停顿到上屏的耗时。OpenRouter 的 JSON 接口会忽略 `prompt`，如果需要传上文或词汇提示，可以考虑使用服务商专属参数 `provider.options`。
4. **整段替换**：只在能够读回校验的输入框中生效（主要是原生控件），网页和 Electron 应用要逐个测试。
5. **刘海胶囊**：在外接显示器、全屏应用、多个桌面空间下的显示位置。

## 后续可以优化的方向

`TranscriptionService` 和 `PolishService` 都按接口格式分支实现，以后接入流式识别（WebSocket）或本地模型时，可以抽象成协议后增加新的实现，不影响其他模块。onboarding 目前直接复用设置窗口中的权限页，后续可以替换成设计文档 §13.3 中描述的分步引导和浮动指引。
