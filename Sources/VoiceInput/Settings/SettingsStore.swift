import Combine
import Foundation

/// The active transcription choice references either a provider catalog entry or a local profile.
struct ActiveModelSelection: Codable, Hashable {
    enum Kind: String, Codable {
        case cloud
        case local
    }

    var kind: Kind
    var providerID: UUID? = nil
    var modelID: String? = nil
    var profileID: UUID? = nil

    static func cloud(providerID: UUID, modelID: String) -> ActiveModelSelection {
        ActiveModelSelection(kind: .cloud, providerID: providerID, modelID: modelID)
    }

    static func local(profileID: UUID) -> ActiveModelSelection {
        ActiveModelSelection(kind: .local, profileID: profileID)
    }
}

/// 全局设置。非敏感数据存 UserDefaults（JSON），API Key 存钥匙串。
/// 旧版本存下的润色开关、词典、繁转简等字段读取时会被忽略。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Local model profiles only. Cloud providers own their model catalogs.
    @Published var profiles: [ModelProfile] = [] { didSet { save() } }
    @Published var providers: [CloudProvider] = [] { didSet { save() } }
    @Published var activeSelection: ActiveModelSelection? { didSet { save() } }
    @Published var insertionMode: InsertionMode = .live { didSet { save() } }
    @Published var playSounds: Bool = true { didSet { save() } }
    /// 用户额外添加的本地模型目录。默认目录始终参与扫描，这里只存追加项。
    @Published var localModelFolders: [String] = [] { didSet { save() } }

    private let defaultsKey = "VoiceInput.Settings.v1"
    private var isLoading = false

    private struct Snapshot: Codable {
        var profiles: [ModelProfile]
        var providers: [CloudProvider]?
        var activeSelection: ActiveModelSelection?
        /// Legacy field from the model-profile storage format.
        var activeTranscriptionID: UUID?
        var insertionMode: InsertionMode
        var playSounds: Bool
        var localModelFolders: [String]?
    }

    private init() {
        load()
        if profiles.isEmpty && providers.isEmpty { installDefaults() }
        ensureActiveSelection()
    }

    // MARK: - 查询

    var activeTranscription: ModelProfile? {
        guard let activeSelection else { return nil }
        return resolvedProfile(for: activeSelection)
    }

    var localProfiles: [ModelProfile] {
        profiles.filter { $0.isLocal }
    }

    func profiles(for role: ModelRole) -> [ModelProfile] {
        profiles.filter { $0.role == role }
    }

    /// All choices shown by the inline "当前使用" disclosure: cloud catalog entries plus local files.
    var availableSelections: [ActiveModelSelection] {
        let cloud = providers.flatMap { provider in
            provider.models.map {
                ActiveModelSelection.cloud(providerID: provider.id, modelID: $0.modelID)
            }
        }
        let local = profiles
            .filter { $0.isLocal && ($0.localModelExists || activeSelection?.profileID == $0.id) }
            .map { ActiveModelSelection.local(profileID: $0.id) }
        return cloud + local
    }

    func provider(for id: UUID) -> CloudProvider? {
        providers.first { $0.id == id }
    }

    func model(for selection: ActiveModelSelection) -> CloudModel? {
        guard selection.kind == .cloud,
              let providerID = selection.providerID,
              let modelID = selection.modelID,
              let provider = provider(for: providerID) else { return nil }
        return provider.models.first { $0.modelID == modelID }
    }

    func resolvedProfile(for selection: ActiveModelSelection) -> ModelProfile? {
        switch selection.kind {
        case .cloud:
            guard let providerID = selection.providerID,
                  let modelID = selection.modelID,
                  let provider = provider(for: providerID),
                  let model = provider.models.first(where: { $0.modelID == modelID }) else {
                return nil
            }
            return .cloudModel(provider: provider, model: model)
        case .local:
            guard let profileID = selection.profileID else { return nil }
            return profiles.first { $0.id == profileID && $0.isLocal }
        }
    }

    /// 本地模型扫描根目录：共享 whisper.cpp 目录、App 自己的模型目录、用户追加目录。
    var localModelRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = [
            home.appendingPathComponent("Library/Application Support/whisper.cpp", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/VoiceInput/Models", isDirectory: true),
            home.appendingPathComponent(".cache/whisper.cpp", isDirectory: true),
        ]
        let custom = localModelFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var seen = Set<String>()
        return (defaults + custom).filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    func addLocalModelFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !localModelFolders.contains(path) else { return }
        localModelFolders.append(path)
    }

    func removeLocalModelFolder(_ path: String) {
        localModelFolders.removeAll { $0 == path }
    }

    func existingProfile(forLocalModelPath path: String) -> ModelProfile? {
        profiles.first { $0.isLocal && $0.localModelPath == path }
    }

    /// Discovered local models join the same model list as cloud catalog entries.
    func addDiscoveredLocalProfile(_ profile: ModelProfile) {
        guard profile.isLocal,
              !profiles.contains(where: {
                  $0.isLocal && $0.localModelPath == profile.localModelPath
              }) else { return }
        profiles.append(profile)
    }

    // MARK: - API Key

    func apiKey(for profile: ModelProfile) -> String {
        let account = profile.providerID ?? profile.id
        return Keychain.load(account: account.uuidString)
    }

    func apiKey(forProviderID id: UUID) -> String {
        Keychain.load(account: id.uuidString)
    }

    func setAPIKey(_ key: String, for profile: ModelProfile) {
        let account = profile.providerID ?? profile.id
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account.uuidString)
        objectWillChange.send()
    }

    func setAPIKey(_ key: String, forProviderID id: UUID) {
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: id.uuidString)
        objectWillChange.send()
    }

    // MARK: - 增删改

    func upsert(_ profile: ModelProfile) {
        guard profile.isLocal else { return }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        ensureActiveSelection()
    }

    func remove(_ profile: ModelProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(account: profile.id.uuidString)
        if activeSelection?.kind == .local, activeSelection?.profileID == profile.id {
            activeSelection = nil
        }
        ensureActiveSelection()
    }

    func upsertProvider(_ provider: CloudProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }

        if activeSelection?.kind == .cloud, activeSelection?.providerID == provider.id {
            if let modelID = activeSelection?.modelID,
               !provider.models.contains(where: { $0.modelID == modelID }) {
                activeSelection = nil
            }
        }
        ensureActiveSelection()
    }

    func removeProvider(_ provider: CloudProvider) {
        providers.removeAll { $0.id == provider.id }
        Keychain.delete(account: provider.id.uuidString)
        if activeSelection?.kind == .cloud, activeSelection?.providerID == provider.id {
            activeSelection = nil
        }
        ensureActiveSelection()
    }

    /// Keep a valid, ready selection whenever the catalog or local files change.
    func ensureActiveSelection() {
        let choices = availableSelections
        guard !choices.isEmpty else {
            activeSelection = nil
            return
        }

        if let activeSelection,
           let profile = resolvedProfile(for: activeSelection),
           profile.isReady(apiKey: apiKey(for: profile)) {
            return
        }

        let ready = choices.first { selection in
            guard let profile = resolvedProfile(for: selection) else { return false }
            return profile.isReady(apiKey: apiKey(for: profile))
        }
        activeSelection = ready ?? choices[0]
    }

    // MARK: - 持久化

    private func installDefaults() {
        let model = CloudModel(modelID: "openai/whisper-large-v3-turbo",
                               name: "OpenAI: Whisper Large V3 Turbo")
        let provider = CloudProvider(name: "OpenRouter",
                                     baseURL: "https://openrouter.ai/api/v1",
                                     models: [model])
        providers = [provider]
        activeSelection = .cloud(providerID: provider.id, modelID: model.modelID)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        isLoading = true

        let legacyCloudProfiles = snapshot.profiles.filter { !$0.isLocal }
        var migratedProviders = snapshot.providers ?? []
        if migratedProviders.isEmpty, !legacyCloudProfiles.isEmpty {
            migratedProviders = legacyCloudProfiles.map { profile in
                let parts = profile.name.components(separatedBy: " · ")
                let providerName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? profile.name
                let modelName = parts.dropFirst().joined(separator: " · ")
                    .nonEmpty ?? profile.model
                return CloudProvider(id: profile.id,
                                     name: providerName,
                                     baseURL: profile.baseURL,
                                     models: [CloudModel(modelID: profile.model, name: modelName)])
            }
        }

        let localProfiles = snapshot.profiles.filter { $0.isLocal }
        profiles = localProfiles
        providers = migratedProviders

        var selection = snapshot.activeSelection
        if selection == nil, let legacyID = snapshot.activeTranscriptionID {
            if localProfiles.contains(where: { $0.id == legacyID }) {
                selection = .local(profileID: legacyID)
            } else if let legacy = legacyCloudProfiles.first(where: { $0.id == legacyID }) {
                selection = .cloud(providerID: legacy.id, modelID: legacy.model)
            } else if let provider = migratedProviders.first(where: { $0.id == legacyID }),
                      let model = provider.models.first {
                selection = .cloud(providerID: provider.id, modelID: model.modelID)
            }
        }
        activeSelection = selection
        insertionMode = snapshot.insertionMode
        playSounds = snapshot.playSounds
        localModelFolders = snapshot.localModelFolders ?? []
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(profiles: profiles,
                                providers: providers,
                                activeSelection: activeSelection,
                                activeTranscriptionID: nil,
                                insertionMode: insertionMode,
                                playSounds: playSounds,
                                localModelFolders: localModelFolders)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
