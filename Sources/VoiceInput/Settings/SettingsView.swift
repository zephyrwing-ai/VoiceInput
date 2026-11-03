import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Tab: Equatable {
        case models
        case permissions
    }

    @State private var tab: Tab = .models

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton("模型服务", .models)
                tabButton("权限", .permissions)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .background(Palette.bg)

            Group {
                switch tab {
                case .models:
                    page { ModelsSettingsView() }
                case .permissions:
                    page { PermissionsSettingsView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 520)
        .background(Palette.bg)
        .preferredColorScheme(.dark)
        .tokenRoot()
    }

    private func tabButton(_ title: String, _ target: Tab) -> some View {
        Button {
            withAnimation(Motion.curve(Motion.fast)) { tab = target }
        } label: {
            Text(title)
                .font(.ui(TypeScale.body, .regular))
                .foregroundStyle(tab == target ? Palette.text : Palette.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Radius.control)
                    .fill(tab == target ? Palette.surfaceHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) { content() }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }
}

// MARK: - 模型服务

struct ModelsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var runtime = LocalModelRuntimeManager.shared
    @State private var editingProvider: CloudProvider?
    @State private var localModels: [LocalModelCandidate] = []
    @State private var scanning = false
    @State private var modelListExpanded = false
    @State private var refreshingProviderID: UUID?
    @State private var providerError: String?

    private struct ModelChoice: Identifiable {
        let id: String
        let title: String
        let selection: ActiveModelSelection
    }

    var body: some View {
        Group {
            SettingsGroup(title: "语音识别") {
                Button {
                    editingProvider = CloudProvider(name: "", baseURL: "", models: [])
                } label: {
                    Label("添加", systemImage: "plus").font(.ui(TypeScale.code))
                }
                .buttonStyle(.borderless).foregroundStyle(Palette.textSecondary)
                .help("添加提供商")
            } content: {
                VStack(alignment: .leading, spacing: Space.sm) {
                    modelSelector
                    providerCards
                    localCards
                    if let providerError {
                        Text(providerError)
                            .font(.ui(TypeScale.caption))
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .sheet(item: $editingProvider) { provider in
            CloudProviderEditorView(provider: provider) { editingProvider = nil }
        }
        .task { await scanLocalModels() }
    }

    private var modelChoices: [ModelChoice] {
        let cloud = store.providers.flatMap { provider in
            provider.models.map { model in
                ModelChoice(
                    id: "cloud:\(provider.id.uuidString):\(model.modelID)",
                    title: "\(provider.name) · \(model.name)",
                    selection: .cloud(providerID: provider.id, modelID: model.modelID)
                )
            }
        }
        let local = localProfiles.map { profile in
            ModelChoice(
                id: "local:\(profile.id.uuidString)",
                title: "本地 · \(localName(profile))",
                selection: .local(profileID: profile.id)
            )
        }
        return cloud + local
    }

    private var selectedTitle: String {
        if let selection = store.activeSelection,
           let choice = modelChoices.first(where: { $0.selection == selection }) {
            return choice.title
        }
        return "选择模型"
    }

    private var localProfiles: [ModelProfile] {
        store.localProfiles.filter {
            $0.localModelExists || store.activeSelection?.profileID == $0.id
        }
    }

    private var modelSelector: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Motion.curve(Motion.expand)) {
                    modelListExpanded.toggle()
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Text("当前使用").textStyle(TypeScale.body, .regular)
                    Spacer(minLength: Space.md)
                    Text(selectedTitle)
                        .textStyle(TypeScale.body, .regular, color: Palette.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .rotationEffect(.degrees(modelListExpanded ? 180 : 0))
                }
                .padding(.horizontal, 2 * Space.frameGap)
                .frame(minHeight: Metrics.listRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if modelListExpanded {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(modelChoices) { choice in
                            Button {
                                store.activeSelection = choice.selection
                                withAnimation(Motion.curve(Motion.expand)) {
                                    modelListExpanded = false
                                }
                            } label: {
                                HStack(spacing: Space.sm) {
                                    Text(choice.title)
                                        .textStyle(TypeScale.meta, .regular)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if choice.selection == store.activeSelection {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(choice.selection == store.activeSelection ? Palette.navSelected : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 240)
                .background(Palette.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.input))
        .overlay(RoundedRectangle(cornerRadius: Radius.control)
            .strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
    }

    @ViewBuilder
    private var providerCards: some View {
        VStack(spacing: Space.sm) {
            ForEach(store.providers) { provider in
                providerCard(provider)
            }
        }
    }

    @ViewBuilder
    private var localCards: some View {
        VStack(spacing: Space.sm) {
            ForEach(localProfiles) { profile in
                localCard(profile)
            }
        }
    }

    private func providerCard(_ provider: CloudProvider) -> some View {
        HStack(spacing: Space.sm) {
            Text(provider.name).textStyle(TypeScale.meta, .regular).lineLimit(1)
            Spacer(minLength: Space.sm)
            if refreshingProviderID == provider.id { TokenSpinner() }
            Button {
                Task { await refresh(provider) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("刷新模型")
            .disabled(refreshingProviderID != nil)

            Button { editingProvider = provider } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help("编辑提供商")

            Button { store.removeProvider(provider) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(danger: true))
            .help("删除提供商")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.input))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
    }

    private func localCard(_ profile: ModelProfile) -> some View {
        let running = runtime.runningModelPath == profile.localModelPath && runtime.state.isRunning
        return HStack(spacing: Space.sm) {
            Text(localName(profile)).textStyle(TypeScale.meta, .regular).lineLimit(1)
            TagView(text: "本地")
            Spacer(minLength: Space.sm)
            if running {
                Circle()
                    .fill(Palette.success)
                    .frame(width: 6, height: 6)
                    .help("运行中")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.input))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
    }

    private func localName(_ profile: ModelProfile) -> String {
        guard let path = profile.localModelPath,
              let candidate = localModels.first(where: { $0.path.path == path }) else {
            return profile.name
        }
        return candidate.name
    }

    private func refresh(_ provider: CloudProvider) async {
        let key = store.apiKey(forProviderID: provider.id)
        guard !key.isEmpty else {
            providerError = "\(provider.name) 缺少 API Key"
            return
        }
        refreshingProviderID = provider.id
        providerError = nil
        do {
            var updated = provider
            updated.models = try await CloudModelCatalog.fetch(baseURL: provider.baseURL, apiKey: key)
            store.upsertProvider(updated)
        } catch {
            providerError = error.localizedDescription
        }
        refreshingProviderID = nil
    }

    private func scanLocalModels() async {
        guard !scanning else { return }
        scanning = true
        let models = await LocalModelScanner.scan(roots: store.localModelRoots)
        localModels = models
        for model in models {
            let path = model.path.path
            guard store.existingProfile(forLocalModelPath: path) == nil else { continue }
            store.addDiscoveredLocalProfile(
                ModelProfile.localModel(name: model.name, path: path, model: model.modelName)
            )
        }
        store.ensureActiveSelection()
        scanning = false
    }
}

// MARK: - 编辑单个模型

/// The provider editor only edits connection data. Saving discovers the provider's
/// model catalog and publishes every available transcription model to the inline selector.
struct CloudProviderEditorView: View {
    @State private var draft: CloudProvider
    @State private var apiKey: String
    @State private var saving = false
    @State private var error: String?
    let onClose: () -> Void

    init(provider: CloudProvider, onClose: @escaping () -> Void) {
        _draft = State(initialValue: provider)
        _apiKey = State(initialValue: SettingsStore.shared.apiKey(forProviderID: provider.id))
        self.onClose = onClose
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBaseURL: String { draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedBaseURL.isEmpty && !trimmedKey.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(draft.models.isEmpty ? "添加提供商" : "编辑提供商")
                    .textStyle(TypeScale.title)
                TokenTextField(label: "名称", text: $draft.name, prompt: "例如：OpenRouter",
                               showsFocusHalo: false)
                TokenTextField(label: "Base URL", text: $draft.baseURL,
                               prompt: "https://openrouter.ai/api/v1", showsFocusHalo: false)
                TokenTextField(label: "API Key", text: $apiKey, secure: true, showsFocusHalo: false)
                if saving {
                    HStack(spacing: Space.sm) {
                        TokenSpinner()
                        Text("正在获取模型…").textStyle(TypeScale.meta, .regular, color: Palette.textMuted)
                    }
                }
                if let error {
                    Text(error).font(.ui(TypeScale.caption)).foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.xl)

            RowDivider()
            HStack(spacing: Space.sm) {
                Spacer()
                Button("取消", role: .cancel) { onClose() }
                    .buttonStyle(SecondaryButtonStyle())
                Button { save() } label: {
                    HStack(spacing: 7) {
                        if saving { TokenSpinner() }
                        Text(saving ? "正在保存…" : "保存")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !canSave)
            }
            .padding(Space.lg)
        }
        .frame(width: 540, height: 360)
        .background(Palette.bg)
        .preferredColorScheme(.dark)
        .tokenRoot()
    }

    private func save() {
        let name = trimmedName
        let baseURL = trimmedBaseURL
        let key = trimmedKey
        guard !name.isEmpty, !baseURL.isEmpty, !key.isEmpty else { return }
        saving = true
        error = nil
        Task {
            do {
                var provider = draft
                provider.name = name
                provider.baseURL = baseURL
                provider.models = try await CloudModelCatalog.fetch(baseURL: baseURL, apiKey: key)
                let store = SettingsStore.shared
                store.setAPIKey(key, forProviderID: provider.id)
                store.upsertProvider(provider)
                onClose()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

// MARK: - 权限

struct PermissionsSettingsView: View {
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        VStack(spacing: Space.sm) {
            permissionCard(title: "麦克风", granted: permissions.microphone == .authorized) {
                permissions.requestMicrophone()
            }
            permissionCard(title: "辅助功能", granted: permissions.accessibility) {
                permissions.requestAccessibility()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { permissions.refresh(); permissions.startPolling() }
    }

    private func permissionCard(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.md) {
            Text(title).textStyle(TypeScale.body, .regular)
            Spacer(minLength: Space.lg)
            if granted {
                TagView(text: "已授权", tone: .success)
            } else {
                Button("去授权", action: action).buttonStyle(SecondaryButtonStyle(size: .compact))
            }
        }
        .padding(.horizontal, 2 * Space.frameGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Metrics.listRowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.input))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
    }
}

// MARK: - 窗口

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(tab: Int = 0) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = PaletteNS.bg
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
