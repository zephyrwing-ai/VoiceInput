import Foundation

/// A GGML model discovered on disk. The model file is user-owned; the app only reads it.
struct LocalModelCandidate: Identifiable, Hashable, Sendable {
    let path: URL
    let byteCount: Int64
    let family: String
    let quantization: String?
    let multilingual: Bool

    var id: String { path.standardizedFileURL.path }

    /// The model field sent to the local OpenAI-compatible endpoint.
    var modelName: String {
        path.deletingPathExtension().lastPathComponent
    }

    var name: String {
        let lower = path.lastPathComponent.lowercased()
        switch family {
        case "tiny": return "Whisper Tiny"
        case "base": return "Whisper Base"
        case "small": return "Whisper Small"
        case "medium": return "Whisper Medium"
        case "large-v3-turbo": return "Whisper Large V3 Turbo"
        case "large-v3": return "Whisper Large V3"
        case "large-v2": return "Whisper Large V2"
        case "large-v1": return "Whisper Large V1"
        case "large":
            if lower.contains("large-v3") { return "Whisper Large V3" }
            if lower.contains("large-v2") { return "Whisper Large V2" }
            if lower.contains("large-v1") { return "Whisper Large V1" }
            return "Whisper Large"
        default:
            return path.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "ggml-", with: "")
        }
    }

    var sizeText: String {
        let mib = Double(byteCount) / 1_048_576
        if mib >= 1024 {
            return String(format: "%.1f GB", mib / 1024)
        }
        return "\(max(1, Int(mib.rounded()))) MB"
    }

    var detailText: String {
        var parts = [sizeText, "GGML"]
        if let quantization { parts.append(quantization.uppercased()) }
        if multilingual { parts.append("多语言") }
        return parts.joined(separator: " · ")
    }
}

/// Reads whisper.cpp GGML model headers and discovers models in known folders.
enum LocalModelScanner {
    private static let magic: UInt32 = 0x67676d6c
    private static let headerBytes = 52
    private static let minimumBytes: Int64 = 1_048_576
    private static let maximumBytes: Int64 = 8 * 1_073_741_824
    private static let maximumDepth = 3
    private static let maximumFiles = 20_000

    static func scan(roots: [URL]) async -> [LocalModelCandidate] {
        await Task.detached(priority: .utility) {
            scanSynchronously(roots: roots)
        }.value
    }

    private static func scanSynchronously(roots: [URL]) -> [LocalModelCandidate] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var found: [String: LocalModelCandidate] = [:]
        var visited = 0

        for root in roots {
            let rootURL = root.standardizedFileURL
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let rootDepth = rootURL.pathComponents.count
            for case let url as URL in enumerator {
                if visited >= maximumFiles { break }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }

                let depth = url.standardizedFileURL.pathComponents.count - rootDepth
                if depth > maximumDepth {
                    if values?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }

                if values?.isDirectory == true {
                    let name = url.lastPathComponent
                    if name == "node_modules" || name == ".git" { enumerator.skipDescendants() }
                    continue
                }

                guard values?.isRegularFile == true,
                      url.pathExtension.lowercased() == "bin",
                      let byteCount = values?.fileSize.map(Int64.init),
                      byteCount >= minimumBytes,
                      byteCount <= maximumBytes else {
                    continue
                }
                visited += 1

                guard let candidate = readCandidate(url: url, byteCount: byteCount) else { continue }
                found[candidate.id] = candidate
            }
        }

        return found.values.sorted {
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.path.path < $1.path.path
        }
    }

    private static func readCandidate(url: URL, byteCount: Int64) -> LocalModelCandidate? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerBytes),
              header.count == headerBytes,
              uint32(header, at: 0) == magic else {
            return nil
        }

        // whisper.cpp GGML header: magic, n_vocab, n_audio_ctx, n_audio_state,
        // n_audio_head, n_audio_layer, n_text_ctx, n_text_state, n_text_head,
        // n_text_layer, n_mels, ftype. ftype includes a 1000-based quantization version.
        let vocabularySize = int32(header, at: 4)
        let audioState = int32(header, at: 12)
        let audioLayers = int32(header, at: 20)
        let textLayers = int32(header, at: 36)
        let fileType = int32(header, at: 44) % 1_000

        let family = familyName(fileName: url.lastPathComponent,
                                audioState: audioState,
                                audioLayers: audioLayers,
                                textLayers: textLayers)
        return LocalModelCandidate(
            path: url.standardizedFileURL,
            byteCount: byteCount,
            family: family,
            quantization: quantizationName(from: url.lastPathComponent) ?? quantizationName(fileType),
            multilingual: vocabularySize > 51_864
        )
    }

    private static func familyName(fileName: String,
                                   audioState: Int32,
                                   audioLayers: Int32,
                                   textLayers: Int32) -> String {
        if audioState == 384 && audioLayers == 4 { return "tiny" }
        if audioState == 512 && audioLayers == 6 { return "base" }
        if audioState == 768 && audioLayers == 12 { return "small" }
        if audioState == 1024 && audioLayers == 24 { return "medium" }
        if audioState == 1280 && audioLayers == 32 {
            if textLayers == 4 { return "large-v3-turbo" }
            let lower = fileName.lowercased()
            if lower.contains("large-v3") { return "large-v3" }
            if lower.contains("large-v2") { return "large-v2" }
            if lower.contains("large-v1") { return "large-v1" }
            return "large"
        }
        return "unknown"
    }

    private static func quantizationName(_ value: Int32) -> String? {
        switch value {
        case 0: return "f32"
        case 1: return "f16"
        case 2: return "q4_0"
        case 3: return "q4_1"
        case 6: return "q5_0"
        case 7: return "q5_1"
        case 8: return "q8_0"
        default: return nil
        }
    }

    private static func quantizationName(from fileName: String) -> String? {
        let lower = fileName.lowercased()
        for name in ["q2_k", "q3_k", "q4_0", "q4_1", "q4_k", "q5_0", "q5_1", "q5_k", "q6_k", "q8_0"] {
            if lower.contains(name) { return name }
        }
        return nil
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func int32(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: uint32(data, at: offset))
    }
}
