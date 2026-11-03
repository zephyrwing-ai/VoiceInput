import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            page { ModelsSettingsView() }.tabItem { Label("模型服务", systemImage: "cpu") }
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

// MARK: - 模型服务

struct ModelsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var editing: ModelProfile?

    var body: some View {
        Group {
            SettingsGroup(title: "语音识别") {
                Button { editing = ModelProfile.newTranscription() } label: {
                    Label("添加", systemImage: "plus").font(.ui(TypeScale.code))
                }
                .buttonStyle(.borderless).foregroundStyle(Palette.textSecondary)
            } content: {
                SettingsList {
                    SettingsRow(title: "当前使用") { activePicker($store.activeTranscriptionID, role: .transcription) }
                    ForEach(store.profiles(for: .transcription)) { RowDivider(); row($0) }
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

/// 用户只填写：名称、Base URL、API Key、模型 ID。
/// 接口格式、超时、语言、零数据保留等由程序自动处理；点"保存"时会先在后台验证一次连接。
struct ModelEditorView: View {
    @State private var draft: ModelProfile
    @State private var apiKey: String
    @State private var saving = false
    @State private var saveError: String?
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

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !trimmedKey.isEmpty
            && !draft.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                TokenTextField(label: "名称", text: $draft.name, prompt: "例如：OpenRouter Whisper")
                TokenTextField(label: "Base URL", text: $draft.baseURL, prompt: "https://openrouter.ai/api/v1")
                TokenTextField(label: "API Key", text: $apiKey, secure: true)
                HStack(alignment: .bottom, spacing: Space.sm) {
                    TokenTextField(label: "模型 ID", text: $draft.model, prompt: "openai/whisper-large-v3-turbo")
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
                Spacer(minLength: 0)
            }
            .padding(Space.xl)

            RowDivider()
            HStack(spacing: Space.sm) {
                if let saveError {
                    Text(saveError).font(.ui(TypeScale.caption)).foregroundStyle(Palette.danger).lineLimit(2)
                }
                Spacer()
                Button("取消", role: .cancel) { onClose() }.buttonStyle(SecondaryButtonStyle())
                Button { save() } label: {
                    HStack(spacing: 7) {
                        if saving { TokenSpinner() }
                        Text(saving ? "正在验证…" : "保存")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !canSave)
            }
            .padding(Space.lg)
        }
        .frame(width: 540, height: 400)
        .background(Palette.surface)
        .tokenRoot()
    }

    /// 保存前在后台验证一次：地址、Key、模型 ID 都可用才保存（接口格式、零数据保留在请求时自动处理）
    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.format = draft.effectiveFormat
        saving = true
        saveError = nil
        let profile = draft
        let key = trimmedKey
        Task {
            let result = await ConnectionTester.test(profile, apiKey: key)
            saving = false
            switch result {
            case .success:
                let store = SettingsStore.shared
                store.upsert(profile)
                store.setAPIKey(key, for: profile)
                onClose()
            case .failure(let error):
                saveError = "验证失败：\(error.localizedDescription)"
            }
        }
    }

    private func fetchModels() {
        fetching = true
        fetchError = nil
        let base = draft.baseURL
        let role = draft.role
        let key = trimmedKey
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
        let previous = draft.model
        draft.model = model.id
        // 名称还没填，或者还是上一个模型的默认名字时，顺便改成所选模型的名字
        let previousName = remoteModels.first(where: { $0.id == previous })?.name
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.name == previousName {
            draft.name = model.name
        }
        for prefix in ["OpenRouter · ", "OpenAI 兼容 · "] where draft.name.hasPrefix(prefix) {
            draft.name = prefix + model.name
        }
        showPicker = false
    }
}

// MARK: - 模型选择弹窗

/// 能识别出适合当前用途的模型时只列出这些（自动筛选），识别不出来时列出全部
struct ModelPickerView: View {
    let models: [RemoteModel]
    let role: ModelRole
    let current: String
    let onSelect: (RemoteModel) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [RemoteModel] {
        let matching = models.filter(\.matchesRole)
        let pool = matching.isEmpty ? models : matching
        return pool.filter { model in
            query.isEmpty
                || model.id.localizedCaseInsensitiveContains(query)
                || model.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                TextField("搜索", text: $query).textFieldStyle(.plain).focused($searchFocused)
            }
            .modifier(InputChrome(focused: searchFocused, height: 36))
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
