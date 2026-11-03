import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            page { ModelsSettingsView() }.tabItem { Label("模型服务", systemImage: "cpu") }
            page { InputSettingsView() }.tabItem { Label("输入", systemImage: "keyboard") }
            page { PermissionsSettingsView() }.tabItem { Label("权限", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 520)
        .background(Palette.surface)
        .tokenRoot()
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) { content() }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
    }
}

private func inkSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
}

// MARK: - 模型服务

struct ModelsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var editing: ModelProfile?

    var body: some View {
        Group {
            SettingsGroup(title: "语音识别") {
                addMenu([("OpenRouter（Whisper Large V3 Turbo）", ModelProfile.openRouterWhisper),
                         ("OpenAI 兼容接口（Groq、OpenAI 等）", ModelProfile.openAICompatibleTranscription)])
            } content: {
                SettingsList {
                    SettingsRow(title: "当前使用") { activePicker($store.activeTranscriptionID, role: .transcription) }
                    ForEach(store.profiles(for: .transcription)) { RowDivider(); row($0) }
                }
            }

            SettingsGroup(title: "文字润色") {
                addMenu([("OpenRouter / OpenAI 兼容对话模型", ModelProfile.openRouterPolish)])
            } content: {
                SettingsList {
                    SettingsRow(title: "松手后润色") { inkSwitch("松手后润色", isOn: $store.polishEnabled) }
                    RowDivider()
                    SettingsRow(title: "当前使用") {
                        activePicker($store.activePolishID, role: .polish).disabled(!store.polishEnabled)
                    }
                    ForEach(store.profiles(for: .polish)) { RowDivider(); row($0) }
                }
            }
        }
        .sheet(item: $editing) { profile in
            ModelEditorView(profile: profile) { editing = nil }
        }
    }

    private func activePicker(_ selection: Binding<UUID?>, role: ModelRole) -> some View {
        Picker("当前使用", selection: selection) {
            Text("未选择").tag(UUID?.none)
            ForEach(store.profiles(for: role)) { Text($0.name).tag(UUID?.some($0.id)) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private func addMenu(_ templates: [(String, () -> ModelProfile)]) -> some View {
        Menu {
            ForEach(templates.indices, id: \.self) { index in
                Button(templates[index].0) { editing = templates[index].1() }
            }
        } label: {
            Label("添加", systemImage: "plus").font(.ui(TypeScale.code))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Palette.textSecondary)
    }

    private func row(_ profile: ModelProfile) -> some View {
        let hasKey = !store.apiKey(for: profile).isEmpty
        return HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).textStyle(TypeScale.body, .regular).lineLimit(1)
                Text(profile.model.isEmpty ? "未填写模型 ID" : profile.model)
                    .font(.mono(TypeScale.code)).foregroundStyle(Palette.textMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.md)
            if !hasKey { TagView(text: "缺少 Key", tone: .warning) }
            Button("编辑") { editing = profile }.buttonStyle(SecondaryButtonStyle(size: .compact))
            Button { store.remove(profile) } label: { Label("删除", systemImage: "trash").labelStyle(.iconOnly) }
                .buttonStyle(IconButtonStyle(danger: true)).help("删除")
        }
        .padding(.vertical, Space.xs + 2)
        .padding(.leading, 2 * Space.frameGap)
        .padding(.trailing, Space.sm)
        .frame(minHeight: Metrics.listRowHeight)
    }
}

// MARK: - 编辑单个模型

struct ModelEditorView: View {
    private enum Outcome { case success(String), failure(String) }

    @State private var draft: ModelProfile
    @State private var apiKey: String
    @State private var testResult: Outcome?
    @State private var testing = false
    @State private var remoteModels: [RemoteModel] = []
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var showPicker = false
    let onClose: () -> Void

    init(profile: ModelProfile, onClose: @escaping () -> Void) {
        _draft = State(initialValue: profile)
        _apiKey = State(initialValue: SettingsStore.shared.apiKey(for: profile))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    TokenTextField(label: "名称", text: $draft.name)
                    Field(label: "接口格式") {
                        Picker("接口格式", selection: $draft.format) {
                            ForEach(APIFormat.formats(for: draft.role)) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    TokenTextField(label: "Base URL", text: $draft.baseURL, prompt: "https://openrouter.ai/api/v1")
                    TokenTextField(label: "API Key", text: $apiKey, secure: true)
                    HStack(alignment: .bottom, spacing: Space.sm) {
                        TokenTextField(label: "模型 ID", text: $draft.model,
                                       prompt: draft.role == .transcription ? "openai/whisper-large-v3-turbo" : "provider/model-name")
                        Button { fetchModels() } label: {
                            HStack(spacing: 7) {
                                if fetching { TokenSpinner() }
                                Text("选择模型")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(size: .field))
                        .disabled(fetching || draft.baseURL.isEmpty)
                        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                            ModelPickerView(models: remoteModels, role: draft.role, current: draft.model) { choose($0) }
                        }
                    }
                    if let fetchError {
                        Text(fetchError).font(.ui(TypeScale.caption)).foregroundStyle(Palette.danger)
                    }
                    if draft.role == .transcription {
                        TokenTextField(label: "语言", text: $draft.language, prompt: "留空自动检测")
                    }
                    Field(label: "Temperature") {
                        HStack(spacing: Space.md) {
                            Slider(value: $draft.temperature, in: 0...1, step: 0.1)
                            Text(String(format: "%.1f", draft.temperature))
                                .font(.mono(TypeScale.code)).foregroundStyle(Palette.textSecondary).frame(width: 28)
                        }
                    }
                    Field(label: "超时") {
                        Stepper(value: $draft.timeout, in: 1...60) {
                            Text("\(Int(draft.timeout)) 秒").font(.mono(TypeScale.code))
                        }
                    }
                    if draft.format == .openRouterTranscription || draft.baseURL.contains("openrouter.ai") {
                        HStack {
                            Text("零数据保留（ZDR）").textStyle(TypeScale.meta, .regular, color: Palette.textSecondary)
                            Spacer()
                            inkSwitch("零数据保留（ZDR）", isOn: $draft.zeroDataRetention)
                        }
                    }
                }
                .padding(Space.xl)
            }

            RowDivider()
            HStack(spacing: Space.sm) {
                Button { runTest() } label: {
                    HStack(spacing: 7) {
                        if testing { TokenSpinner() }
                        Text("测试")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(testing || apiKey.isEmpty || draft.model.isEmpty)
                if let testResult { outcomeText(testResult) }
                Spacer()
                Button("取消", role: .cancel) { onClose() }.buttonStyle(SecondaryButtonStyle())
                Button("保存") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.isEmpty || draft.baseURL.isEmpty)
            }
            .padding(Space.lg)
        }
        .frame(width: 540, height: 530)
        .background(Palette.surface)
        .tokenRoot()
    }

    private func outcomeText(_ outcome: Outcome) -> some View {
        Group {
            switch outcome {
            case .success: Label("连接正常", systemImage: "checkmark").foregroundStyle(Palette.success)
            case .failure(let message): Text(message).foregroundStyle(Palette.danger).lineLimit(2)
            }
        }
        .font(.ui(TypeScale.caption))
    }

    private func save() {
        let store = SettingsStore.shared
        store.upsert(draft)
        store.setAPIKey(apiKey, for: draft)
        onClose()
    }

    private func fetchModels() {
        fetching = true
        fetchError = nil
        let base = draft.baseURL
        let role = draft.role
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                remoteModels = try await ModelCatalog.fetch(baseURL: base, apiKey: key, role: role)
                showPicker = !remoteModels.isEmpty
                if remoteModels.isEmpty { fetchError = "没有可用的模型" }
            } catch {
                fetchError = error.localizedDescription
            }
            fetching = false
        }
    }

    private func choose(_ model: RemoteModel) {
        draft.model = model.id
        // 名称还是模板默认值时，顺便改成所选模型的名字
        for prefix in ["OpenRouter · ", "OpenAI 兼容 · "] where draft.name.hasPrefix(prefix) {
            draft.name = prefix + model.name
        }
        showPicker = false
    }

    private func runTest() {
        testing = true
        testResult = nil
        let profile = draft
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await ConnectionTester.test(profile, apiKey: key)
            testing = false
            switch result {
            case .success(let message): testResult = .success(message)
            case .failure(let error): testResult = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - 模型选择弹窗

struct ModelPickerView: View {
    let models: [RemoteModel]
    let role: ModelRole
    let current: String
    let onSelect: (RemoteModel) -> Void

    @State private var query = ""
    @State private var onlyMatching = true
    @FocusState private var searchFocused: Bool

    private var hasMatching: Bool { models.contains(where: \.matchesRole) }

    private var filtered: [RemoteModel] {
        models.filter { model in
            (!onlyMatching || !hasMatching || model.matchesRole)
                && (query.isEmpty
                    || model.id.localizedCaseInsensitiveContains(query)
                    || model.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                TextField("搜索", text: $query).textFieldStyle(.plain).focused($searchFocused)
            }
            .modifier(InputChrome(focused: searchFocused, height: 36))
            if hasMatching {
                Toggle("只看\(role.displayName)模型", isOn: $onlyMatching)
                    .toggleStyle(.checkbox)
                    .font(.ui(TypeScale.meta, .regular))
                    .foregroundStyle(Palette.textSecondary)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { model in
                        Button { onSelect(model) } label: {
                            HStack(spacing: Space.md) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.name).font(.ui(TypeScale.body, .regular)).lineLimit(1)
                                    Text(model.id).font(.mono(TypeScale.caption)).foregroundStyle(Palette.textMuted)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if model.id == current {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(NavItemStyle(selected: model.id == current))
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 420, height: 440)
        .background(Palette.surface)
        .tokenRoot()
    }
}

// MARK: - 输入

struct InputSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @FocusState private var dictionaryFocused: Bool

    var body: some View {
        SettingsGroup(title: "快捷键") {
            SettingsList {
                SettingsRow(title: "按住说话") { KeyCaps(keys: ["Fn", "Control"]) }
            }
        }

        SettingsGroup(title: "上屏") {
            SettingsList {
                SettingsRow(title: "方式") {
                    Picker("方式", selection: $store.insertionMode) {
                        ForEach(InsertionMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                RowDivider()
                SettingsRow(title: "繁体转简体") { inkSwitch("繁体转简体", isOn: $store.convertToSimplified) }
                RowDivider()
                SettingsRow(title: "提示音") { inkSwitch("提示音", isOn: $store.playSounds) }
            }
        }

        SettingsGroup(title: "个人词典") {
            TextEditor(text: Binding(
                get: { store.dictionary.joined(separator: "\n") },
                set: { store.dictionary = $0.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            .font(.mono(TypeScale.code))
            .scrollContentBackground(.hidden)
            .focused($dictionaryFocused)
            .padding(.vertical, Space.sm)
            .modifier(InputChrome(focused: dictionaryFocused, height: 120))
        }
    }
}

// MARK: - 权限

struct PermissionsSettingsView: View {
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        SettingsList {
            permissionRow(title: "麦克风", granted: permissions.microphone == .authorized) {
                permissions.requestMicrophone()
            }
            RowDivider()
            permissionRow(title: "辅助功能", granted: permissions.accessibility) {
                permissions.requestAccessibility()
            }
        }
        .onAppear { permissions.refresh(); permissions.startPolling() }
    }

    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title) {
            if granted {
                TagView(text: "已授权", tone: .success)
            } else {
                Button("去授权", action: action).buttonStyle(SecondaryButtonStyle(size: .compact))
            }
        }
    }
}

// MARK: - 窗口

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(tab: Int = 0) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "VoiceInput 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.backgroundColor = PaletteNS.surface
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
