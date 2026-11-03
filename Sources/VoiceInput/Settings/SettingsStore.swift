import Foundation
import Combine

/// 全局设置。非敏感数据存 UserDefaults（JSON），API Key 存钥匙串。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var profiles: [ModelProfile] = [] { didSet { save() } }
    @Published var activeTranscriptionID: UUID? { didSet { save() } }
    @Published var activePolishID: UUID? { didSet { save() } }
    @Published var polishEnabled: Bool = true { didSet { save() } }
    @Published var insertionMode: InsertionMode = .live { didSet { save() } }
    @Published var convertToSimplified: Bool = true { didSet { save() } }
    /// 用户词典：每行一个词，传给润色模型
    @Published var dictionary: [String] = [] { didSet { save() } }
    @Published var playSounds: Bool = true { didSet { save() } }

    private let defaultsKey = "VoiceInput.Settings.v1"
    private var isLoading = false

    private struct Snapshot: Codable {
        var profiles: [ModelProfile]
        var activeTranscriptionID: UUID?
        var activePolishID: UUID?
        var polishEnabled: Bool
        var insertionMode: InsertionMode
        var convertToSimplified: Bool
        var dictionary: [String]
        var playSounds: Bool
    }

    private init() {
        load()
        if profiles.isEmpty { installDefaults() }
    }

    // MARK: - 查询

    var activeTranscription: ModelProfile? {
        profiles.first { $0.id == activeTranscriptionID && $0.role == .transcription }
    }

    var activePolish: ModelProfile? {
        // 润色入口已经移除，不再在后台调用隐藏的模型；旧配置与 API Key 保留。
        nil
    }

    func profiles(for role: ModelRole) -> [ModelProfile] {
        profiles.filter { $0.role == role }
    }

    // MARK: - API Key

    func apiKey(for profile: ModelProfile) -> String {
        Keychain.load(account: profile.id.uuidString)
    }

    func setAPIKey(_ key: String, for profile: ModelProfile) {
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.id.uuidString)
        objectWillChange.send()
    }

    // MARK: - 增删改

    func upsert(_ profile: ModelProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        // 该用途还没有选中的模型时，自动选中新加的这个
        switch profile.role {
        case .transcription where activeTranscription == nil: activeTranscriptionID = profile.id
        case .polish where profiles.first(where: { $0.id == activePolishID }) == nil: activePolishID = profile.id
        default: break
        }
    }

    func remove(_ profile: ModelProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(account: profile.id.uuidString)
        if activeTranscriptionID == profile.id { activeTranscriptionID = profiles(for: .transcription).first?.id }
        if activePolishID == profile.id { activePolishID = profiles(for: .polish).first?.id }
    }

    // MARK: - 持久化

    private func installDefaults() {
        let whisper = ModelProfile.openRouterWhisper()
        let polish = ModelProfile.openRouterPolish()
        profiles = [whisper, polish]
        activeTranscriptionID = whisper.id
        activePolishID = polish.id
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        isLoading = true
        profiles = snapshot.profiles
        activeTranscriptionID = snapshot.activeTranscriptionID
        activePolishID = snapshot.activePolishID
        polishEnabled = snapshot.polishEnabled
        insertionMode = snapshot.insertionMode
        convertToSimplified = snapshot.convertToSimplified
        dictionary = snapshot.dictionary
        playSounds = snapshot.playSounds
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(profiles: profiles,
                                activeTranscriptionID: activeTranscriptionID,
                                activePolishID: activePolishID,
                                polishEnabled: polishEnabled,
                                insertionMode: insertionMode,
                                convertToSimplified: convertToSimplified,
                                dictionary: dictionary,
                                playSounds: playSounds)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
