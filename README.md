# VoiceInput（macOS 语音输入框架）

在任意应用中按住 **Fn + Control** 说话，松开结束。录音原样发送给当前语音识别模型，可以使用 OpenRouter / OpenAI 兼容的云端服务，也可以使用本机 whisper.cpp 的 GGML 模型。模型识别出的文字**不做任何修改**，直接写进当前光标所在的输入框。

这是一个可以运行的框架版本：主流程已经接通，各模块按设计文档拆分，方便后续逐个替换和优化。

## 构建与运行

需要 macOS 14 及以上、Xcode 16 及以上（当前在 macOS 26.5 + Xcode 26.6 + Swift 6.3 上验证）。

```bash
cd VoiceInput
swift test                      # 单元测试（组合键、分段拼接、WAV、模型扫描、自动配置）
./scripts/build_app.sh          # 打包成 build/VoiceInput.app（ad-hoc 签名）
OPEN=1 ./scripts/build_app.sh   # 打包并启动
```

开发时也可以直接用 Xcode 打开 `Package.swift` 编辑代码。但麦克风权限要求 App 带有 Info.plist，所以运行时请使用脚本打出来的 `.app`。

`Support/whisper-server` 是随 App 打包的静态 arm64 运行组件，打包脚本会把它复制到 `VoiceInput.app/Contents/Resources/` 并签名。模型权重放在用户目录，App 包只携带运行组件。

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

首次启动会打开新手引导，集中完成麦克风、辅助功能和语音识别模型的配置。首次引导只出现一次，状态保存在 UserDefaults 的 `VoiceInput.Onboarding.hasBeenShown` 中。

后续启动只静默检查权限和模型状态，不自动弹系统授权框，也不自动打开设置窗口。用户在首次引导中拒绝或跳过，或者之后主动关闭权限，App 会保持当前状态；需要重新授权时，从菜单栏打开“设置” → “权限”，点击“去授权”即可。

开发时如果希望重新测试首次引导，可以删除状态后重新启动：

```bash
defaults delete com.manus.voiceinput VoiceInput.Onboarding.hasBeenShown
```

麦克风和辅助功能授权由 macOS TCC 管理。构建脚本会优先使用本机可用的稳定签名身份 `Rig Local Development`；如果该身份不存在，则回退到 ad-hoc，并在每次重编译后重新授权。也可以通过 `SIGN_IDENTITY="VoiceInput Dev" ./scripts/build_app.sh` 指定其他固定身份。

| 页签 | 内容 |
|---|---|
| 模型服务 | 统一的语音识别模型列表。云端提供商填写名称、Base URL 和 API Key，保存时自动拉取模型目录；本地 GGML 模型自动扫描并加入同一个选择列表 |
| 权限 | 麦克风和辅助功能的状态与授权按钮 |

接口格式、超时、语言、零数据保留都由程序自动处理，用户不需要选择：Base URL 是 OpenRouter 时使用它的 JSON 接口，并优先只路由到零数据保留（ZDR）端点，所选模型没有这类端点时自动改用普通路由；其他服务一律使用 OpenAI 兼容的 multipart 接口。超时按录音长度自动计算（15～120 秒），语言自动检测。

| 接口格式 | 地址 | 适用 |
|---|---|---|
| OpenRouter 语音转写（JSON） | `{base}/audio/transcriptions`，base64 音频 | OpenRouter（默认） |
| OpenAI 兼容语音转写（multipart） | `{base}/audio/transcriptions`，上传文件 | OpenAI、Groq、本地 whisper.cpp |

请求里只有音频和模型 ID（OpenRouter 另带零数据保留路由参数），不附加上文、词典等提示词。

API Key 存在系统钥匙串里，不写进配置文件。其他设置存在 UserDefaults 里（键名 `VoiceInput.Settings.v1`）。

云端模型使用“提供商”配置：保存提供商时调用 `{base}/models`，对 OpenRouter 追加 `output_modalities=transcription`，自动把返回的语音转写模型加入“当前使用”的内联展开列表。编辑提供商时也会重新拉取目录；刷新按钮可以手动刷新。模型选择不再放在添加/编辑表单中，统一在当前使用的内联披露列表中完成。

### 本地模型

本地模型使用 whisper.cpp 的 GGML `.bin` 格式。OpenAI 的 `openai/whisper-large-v3` 仓库提供 PyTorch 权重；whisper.cpp 使用同一模型的 GGML 转换版，例如 `ggerganov/whisper.cpp` 仓库中的 `ggml-large-v3-q5_0.bin`。

共享模型目录：

```text
~/Library/Application Support/whisper.cpp/
  ggml-large-v3-q5_0.bin
```

VoiceInput 默认扫描以下目录，也可以通过“添加文件夹”加入自己的模型目录：

- `~/Library/Application Support/whisper.cpp`
- `~/Library/Application Support/VoiceInput/Models`
- `~/.cache/whisper.cpp`

`Project/I` 的语音模型扫描器也覆盖 `~/Library/Application Support/whisper.cpp`，因此同一份模型可以供两个 App 使用。模型文件保留一份，`whisper-cli` 和 `whisper-server` 作为各自的运行组件留在各自 App 中。

本地模型条目显示模型名称和“本地”标记。选中本地模型后，首次录音会启动随包的 `whisper-server`，加载模型并通过 `http://127.0.0.1:<port>/v1/audio/transcriptions` 提供 OpenAI 兼容接口。模型加载后会在内存中复用，空闲 5 分钟后自动停止；再次录音时按需启动。服务绑定 `127.0.0.1`，只接受本机连接。

云端服务的 API Key 必填；本地服务将 API Key 留空即可，填写后会作为普通 Bearer 头发送。

## 处理流程

```
按下 Fn + Control
  → 记录当前焦点输入框（FocusInspector）：所属 App、类别、是否可编辑、是否密码框 / 搜索框
  → 开始录音（AudioRecorder，跟随系统默认输入设备，16kHz 单声道）
  → 刘海胶囊显示波纹；300ms 内没有收到音频时显示"麦克风准备中"
录音中（实时模式）
  → 按停顿切段（VoiceActivitySegmenter：停顿 550ms 或单段满 9 秒）
  → 每段发送到当前识别模型（云端或本地）→ 按系统语言统一简繁 → 写进输入框（按顺序）
松开
  → 刘海旁边显示 "Translating…"，直到识别结果出来
  → 识别最后一段并写入 → 恢复剪贴板
  → 按住不到 0.3 秒视为误触；录音中按其他键会取消
```

识别结果不经过内容加工：不删除"嗯""呃"等语气词，不去掉重复，不补标点、不加空格，也不调用润色模型。只去掉模型返回文字首尾的空白。实时模式下多段拼接时，中文直接连在一起（不补逗号）；只有两段相接处都是英文等用空格分词的文字时补一个空格，避免单词粘连。

### 简繁统一（按系统语言）

Whisper 对所有中文只用一个语言代码 `zh`，同一句普通话有时输出简体、有时输出繁体；实时模式下每段单独识别，同一句话里也可能简繁混杂。所以每次按下快捷键时，程序会读取系统首选语言列表（系统设置 → 通用 → 语言与地区），按其中**排在最前面的中文**决定输出哪一种字形：

| 首选语言列表 | 中文输出 |
|---|---|
| `en-JP, zh-Hans-JP, ja-JP` | 简体（界面语言是英文，但第一个中文条目是简体） |
| `zh-Hans-CN` / `zh-CN` | 简体 |
| `zh-Hant-TW` / `zh-TW` / `zh-HK` / `yue-Hant-HK` | 繁体 |
| 列表里没有中文 | 保持模型原样，不转换 |

转换使用系统自带的 ICU 规则（`Hant-Hans` / `Hans-Hant`），只换字形，不改用词（例如"軟體"转成"软体"而不是"软件"）。含有日文假名的结果不转换，避免改动日文汉字。简体转繁体时少数一对多的字可能选错，例如"干活"会转成"乾活"；繁体转简体基本没有这个问题。

搜索框，以及找不到可编辑输入框的情况，会自动改为"松手后一次性处理"。如果最终无法写入，会在刘海下方显示卡片，文字已复制到剪贴板。

### 刘海悬停菜单

鼠标停在屏幕顶部正中间约 0.15 秒，就会从刘海展开一个菜单，内容和点击菜单栏麦克风图标时一样：当前状态、复制上一次结果、设置、退出。鼠标离开菜单和刘海约 0.35 秒后自动收起。

- 感应区：有刘海的屏幕就是刘海本身；没有刘海的屏幕（外接显示器等）是菜单栏正中间 160pt 宽的一段，菜单栏自动隐藏时是屏幕最顶上 4pt 的一条。
- 只在浮层空闲时弹出：录音、识别中、结果卡片、提示信息显示期间悬停不会打断它们；菜单打开时按下快捷键，会直接切换成录音状态。
- 菜单上不显示上一次结果的原文（共享屏幕时不会被看到），只提供复制。
- 用全局 `mouseMoved` 监听实现，鼠标不动时没有开销，监听鼠标事件也不需要额外权限。浮层不会成为 key window，不会抢走当前输入框的焦点。

## 目录结构

```
Sources/VoiceInput/
├─ App/VoiceInputApp.swift          入口、菜单栏图标
├─ Session/DictationController.swift 一次"按住说"的完整流程
├─ Hotkey/HotkeyMonitor.swift       CGEventTap + Fn/Control 组合键状态机
├─ Audio/AudioRecorder.swift        麦克风采集、重采样、音量电平
├─ Audio/AudioProcessing.swift      WAV 编码、按停顿分段
├─ Services/ModelServices.swift     语音识别的 HTTP 客户端、测试连接
├─ Services/LocalModelScanner.swift 本地 GGML 模型扫描与文件头解析
├─ Services/LocalModelRuntime.swift 本地 whisper-server 的启动、健康检查和空闲停止
├─ Text/TranscriptJoiner.swift      实时模式下各段识别结果的拼接
├─ Text/ChineseScript.swift         按系统首选语言统一简繁字形
├─ Text/AppCategory.swift           App 分类表（仅用于日志）
├─ Focus/FocusInspector.swift       焦点识别、AX 工具、Electron / Chrome 结构树开关
├─ Insertion/TextInserter.swift     AX 写入、粘贴、剪贴板备份与恢复
├─ HUD/                             刘海胶囊（NSPanel + SwiftUI）、悬停菜单与感应区（NotchHover.swift）
├─ Permissions/PermissionManager.swift
└─ Settings/                        模型配置、钥匙串、设置界面

Support/
├─ whisper-server                   静态 arm64 的 whisper.cpp 服务端
├─ LICENSE.whisper.cpp              whisper.cpp 的上游 MIT 许可证
└─ LICENSE.whisper                  OpenAI Whisper 的上游 MIT 许可证
```

## 已验证 / 待验证

已验证：工程能够编译和打包；29 个单元测试通过（其中真实本地模型集成测试默认跳过，设置 `VOICEINPUT_LOCAL_MODEL_TEST=1` 后运行）；本地 `large-v3` 模型可以启动服务并完成转写；App 可以启动并常驻菜单栏，没有崩溃。

以下内容需要在真机上授权并配置模型后实测：

1. **快捷键**：外接键盘可能没有 Fn 键。另外，系统设置里"按下 🌐 键时"的行为（切换输入法、表情等）可能和组合键冲突。
2. **粘贴**：实时模式下，用户仍然按着 Fn + Control，这时程序发出的 ⌘V 只带 Command 标志，需要在各个应用中验证不会变成别的组合键。原生控件优先使用 AX 直接写入，不受这个问题影响。
3. **分段识别的准确率和延迟**：短段落缺少上下文，准确率可能低于整段识别；每一段都是一次 HTTP 请求，需要测量从停顿到上屏的耗时。
4. **原样输出的副作用**：Whisper 在静音或噪声上偶尔会输出"谢谢观看""字幕由……提供"之类的句子，现在会原样写入，不再过滤。
5. **刘海胶囊**：在外接显示器、全屏应用、多个桌面空间下的显示位置。

## 后续可以优化的方向

`TranscriptionService` 按接口格式分支实现，以后接入流式识别（WebSocket）时可以继续扩展新的实现，不影响本地模型路径。onboarding 目前直接复用设置窗口中的权限页，后续可以替换成设计文档 §13.3 中描述的分步引导和浮动指引。
