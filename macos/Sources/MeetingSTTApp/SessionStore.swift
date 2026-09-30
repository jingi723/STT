import AudioToolbox
import CoreAudio
import Foundation

public enum MeetingSTTCoreError: LocalizedError {
    case projectRootNotFound([String])
    case missingProjectPaths([URL])
    case invalidSessionID(String)
    case sessionNotFound(String)
    case corruptMetadata(URL, Error)
    case invalidTranscript(URL, String)
    case unsafePath(URL)
    case activeSession(String)
    case processAlreadyRunning
    case noProcessRunning
    case processLaunch(String)
    case processFailed(executable: String, status: Int32, stderr: String)
    case missingOutput(URL)
    case recording(String)

    public var errorDescription: String? {
        switch self {
        case .projectRootNotFound(let tried):
            return "meeting_stt 프로젝트 루트를 찾을 수 없습니다. 확인한 경로: \(tried.joined(separator: ", "))"
        case .missingProjectPaths(let urls):
            return "프로젝트 필수 경로가 없습니다: \(urls.map(\.path).joined(separator: ", "))"
        case .invalidSessionID(let id): return "잘못된 녹음 세션 ID입니다: \(id)"
        case .sessionNotFound(let id): return "녹음 세션이 없습니다: \(id)"
        case .corruptMetadata(let url, let error): return "metadata를 읽을 수 없어 원본을 보존했습니다 (\(url.path)): \(error.localizedDescription)"
        case .invalidTranscript(let url, let reason): return "전사 결과가 올바르지 않습니다 (\(url.path)): \(reason)"
        case .unsafePath(let url): return "outputs 밖 경로에는 작업할 수 없습니다: \(url.path)"
        case .activeSession(let id): return "녹음 중인 세션은 정지 후 삭제하세요: \(id)"
        case .processAlreadyRunning: return "이미 실행 중인 작업이 있습니다."
        case .noProcessRunning: return "실행 중인 작업이 없습니다."
        case .processLaunch(let message): return "프로세스를 시작하지 못했습니다: \(message)"
        case .processFailed(let executable, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable)이 종료 코드 \(status)로 실패했습니다.\(detail.isEmpty ? "" : "\n\(detail)")"
        case .missingOutput(let url): return "작업은 종료됐지만 예상 결과가 없습니다: \(url.path)"
        case .recording(let message): return message
        }
    }
}

public struct ProjectEnvironment: Equatable, Sendable {
    public let rootURL: URL
    public let pythonURL: URL
    public var outputsURL: URL { rootURL.appendingPathComponent("outputs", isDirectory: true) }
    public var recordingsURL: URL { outputsURL.appendingPathComponent("recordings", isDirectory: true) }
    public var appTapURL: URL { rootURL.appendingPathComponent("native/apptap") }
    public var modelURL: URL { rootURL.appendingPathComponent("models/Qwen3-ASR", isDirectory: true) }

    public init(rootURL: URL) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = root
        let candidates = ["STT_env/bin/python", ".venv/bin/python", "venv/bin/python"]
            .map { root.appendingPathComponent($0) }
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MeetingSTTCoreError.missingProjectPaths(candidates)
        }
        self.pythonURL = python
        try validate()
    }

    public func validate() throws {
        let required = [
            rootURL.appendingPathComponent("meeting_stt/__main__.py"),
            appTapURL,
            modelURL,
        ]
        let missing = required.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else { throw MeetingSTTCoreError.missingProjectPaths(missing) }
    }

    public static func resolve() throws -> ProjectEnvironment {
        if let raw = ProcessInfo.processInfo.environment["MEETING_STT_ROOT"], !raw.isEmpty {
            return try ProjectEnvironment(rootURL: URL(fileURLWithPath: raw, isDirectory: true))
        }
        var candidates: [URL] = []
        var bundleCandidate = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(bundleCandidate)
            let parent = bundleCandidate.deletingLastPathComponent()
            if parent == bundleCandidate { break }
            bundleCandidate = parent
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let saved = UserDefaults.standard.string(forKey: "MeetingSTTProjectRoot") {
            candidates.append(URL(fileURLWithPath: saved, isDirectory: true))
        }

        var tried: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { continue }
            tried.append(url.path)
            let marker = url.appendingPathComponent("meeting_stt/__main__.py")
            if FileManager.default.fileExists(atPath: marker.path) {
                let environment = try ProjectEnvironment(rootURL: url)
                UserDefaults.standard.set(url.path, forKey: "MeetingSTTProjectRoot")
                return environment
            }
        }
        throw MeetingSTTCoreError.projectRootNotFound(tried)
    }
}

public enum MetadataValue: Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    fileprivate var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

public struct RecordingSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let directoryURL: URL
    public var name: String?
    public let status: String
    public let source: String?
    public let deviceID: AudioDeviceID?
    public let pid: pid_t?
    public let createdAt: String?
    public let startedAt: String?
    public let stoppedAt: String?
    public let duration: TimeInterval?
    public let bytes: Int64
    public let audioURL: URL?
    public let transcriptJSONURL: URL?
    public let transcriptMarkdownURL: URL?
    public let promptURL: URL?
    public let transcribed: Bool
    public let metadataError: String?
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let speaker: String
    public let start: Double
    public let end: Double
    public let text: String
}

public struct TranscriptDocument: Decodable, Equatable, Sendable {
    public let audioPath: String
    public let segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case audioPath = "audio_path"
        case segments
    }

    public var text: String { segments.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n") }
}

public struct DeletionResult: Equatable, Sendable {
    public let removed: [URL]
    public let errors: [String]
}

/// 저장 프로퍼티가 전부 `let`이고 metadata 쓰기는 `lock`으로 직렬화된다 — 백그라운드에서 호출해도 안전하다.
public final class SessionStore: @unchecked Sendable {
    public let environment: ProjectEnvironment
    private let fileManager: FileManager
    private let lock = NSLock()
    /// outputs 루트를 심링크 해석한 결과. 경로 검사마다 다시 해석하면 세션 수만큼 경로 전체를 lstat으로 걷게 된다.
    private let outputsComponents: [String]

    public convenience init(rootURL: URL) throws {
        try self.init(environment: ProjectEnvironment(rootURL: rootURL))
    }

    public init(environment: ProjectEnvironment, fileManager: FileManager = .default) throws {
        self.environment = environment
        self.fileManager = fileManager
        self.outputsComponents = environment.outputsURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        try fileManager.createDirectory(at: environment.recordingsURL, withIntermediateDirectories: true)
    }

    public func list() throws -> [RecordingSession] {
        try lock.withLock {
            let recordingsRoot = environment.recordingsURL.standardizedFileURL.resolvingSymlinksInPath()
            let directories = try fileManager.contentsOfDirectory(
                at: environment.recordingsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).compactMap { candidate -> URL? in
                guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true
                else { return nil }
                let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
                return resolved.deletingLastPathComponent() == recordingsRoot ? resolved : nil
            }

            var sessions: [RecordingSession] = []
            for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let audioURL = directory.appendingPathComponent("audio.wav")
                var metadata: [String: Any]
                do {
                    metadata = try readMetadata(directory: directory, allowMissing: true)
                } catch {
                    guard fileManager.fileExists(atPath: audioURL.path) else { throw error }
                    sessions.append(makeSession(directory: directory, metadata: [:], metadataError: error.localizedDescription))
                    continue
                }
                if metadata["status"] as? String == "recording" {
                    let recovered = isValidWAV(audioURL)
                    metadata["status"] = recovered ? "recorded" : "error"
                    if !recovered { metadata["error"] = "앱 종료 후 유효한 WAV를 찾지 못했습니다." }
                    try writeMetadata(metadata, directory: directory)
                }
                if !metadata.isEmpty || fileManager.fileExists(atPath: audioURL.path) {
                    sessions.append(makeSession(directory: directory, metadata: metadata))
                }
            }
            return sessions
        }
    }

    public func create(source: String, device: AudioDeviceID? = nil, pid: pid_t? = nil) throws -> RecordingSession {
        try lock.withLock {
            guard ["device", "app", "system", "systemAndMic"].contains(source) else {
                throw MeetingSTTCoreError.recording("지원하지 않는 녹음 소스입니다: \(source)")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let base = formatter.string(from: Date())
            var id = base
            var suffix = 2
            while fileManager.fileExists(atPath: try sessionDirectory(id).path) {
                id = "\(base)_\(suffix)"
                suffix += 1
            }
            let directory = try sessionDirectory(id)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            let audioURL = directory.appendingPathComponent("audio.wav")
            let now = Self.timestamp()
            let metadata: [String: Any] = [
                "session_id": id,
                "session_dir": directory.path,
                "status": "recording",
                "source": source,
                "device": device.map { Int64($0) } ?? NSNull(),
                "pid": pid.map { Int64($0) } ?? NSNull(),
                "created_at": now,
                "started_at": now,
                "started_at_epoch": Date().timeIntervalSince1970,
                "audio_path": audioURL.path,
                "audio_url": "/api/recordings/\(id)/audio",
            ]
            try writeMetadata(metadata, directory: directory)
            return makeSession(directory: directory, metadata: metadata, includePendingAudio: true)
        }
    }

    public func merge(
        sessionID: String,
        fields: [String: MetadataValue],
        removing: Set<String> = []
    ) throws {
        try lock.withLock {
            let directory = try existingSessionDirectory(sessionID)
            var metadata = try readMetadata(directory: directory, allowMissing: true)
            for key in removing { metadata.removeValue(forKey: key) }
            for (key, value) in fields { metadata[key] = value.jsonObject }
            try writeMetadata(metadata, directory: directory)
        }
    }

    public func rename(sessionID: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try merge(
            sessionID: sessionID,
            fields: trimmed.isEmpty ? [:] : ["name": .string(trimmed)],
            removing: trimmed.isEmpty ? ["name"] : []
        )
    }

    public func delete(sessionID: String, activeSessionID: String? = nil) throws -> DeletionResult {
        try lock.withLock {
            if activeSessionID == sessionID { throw MeetingSTTCoreError.activeSession(sessionID) }
            let directory = try existingSessionDirectory(sessionID)
            let metadata = (try? readMetadata(directory: directory, allowMissing: true)) ?? [:]
            var candidates = [
                environment.outputsURL.appendingPathComponent("\(sessionID).json"),
                environment.outputsURL.appendingPathComponent("\(sessionID).md"),
                environment.outputsURL.appendingPathComponent("\(sessionID).partial.json"),
                environment.outputsURL.appendingPathComponent("\(sessionID).prompt.md"),
            ]
            for key in ["transcript_json", "transcript_md"] {
                if let path = metadata[key] as? String { candidates.append(URL(fileURLWithPath: path)) }
            }

            var removed: [URL] = []
            var errors: [String] = []
            var seen = Set<String>()
            for candidate in candidates {
                let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard seen.insert(resolved.path).inserted else { continue }
                guard isInsideOutputs(resolved), !isInside(resolved, parent: directory) else { continue }
                guard fileManager.fileExists(atPath: resolved.path) else { continue }
                do {
                    try fileManager.removeItem(at: resolved)
                    removed.append(resolved)
                } catch {
                    errors.append("\(resolved.path): \(error.localizedDescription)")
                }
            }
            do {
                try fileManager.removeItem(at: directory)
                removed.append(directory)
            } catch {
                throw MeetingSTTCoreError.recording("세션 삭제 실패 (\(directory.path)): \(error.localizedDescription)")
            }
            return DeletionResult(removed: removed, errors: errors)
        }
    }

    public func loadTranscript(sessionID: String) throws -> TranscriptDocument {
        try lock.withLock {
            let directory = try existingSessionDirectory(sessionID)
            let metadata = try readMetadata(directory: directory, allowMissing: true)
            let defaultURL = environment.outputsURL.appendingPathComponent("\(sessionID).json")
            let url = (metadata["transcript_json"] as? String).map(URL.init(fileURLWithPath:)) ?? defaultURL
            guard isInsideOutputs(url.standardizedFileURL.resolvingSymlinksInPath()) else {
                throw MeetingSTTCoreError.unsafePath(url)
            }
            do {
                let document = try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: url))
                guard document.audioPath == directory.appendingPathComponent("audio.wav").path else {
                    throw MeetingSTTCoreError.invalidTranscript(url, "audio_path가 세션 오디오와 다릅니다.")
                }
                return document
            } catch let error as MeetingSTTCoreError {
                throw error
            } catch {
                throw MeetingSTTCoreError.invalidTranscript(url, error.localizedDescription)
            }
        }
    }

    private func sessionDirectory(_ id: String) throws -> URL {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw MeetingSTTCoreError.invalidSessionID(id)
        }
        let recordingsRoot = environment.recordingsURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = environment.recordingsURL
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent() == recordingsRoot else {
            throw MeetingSTTCoreError.invalidSessionID(id)
        }
        return directory
    }

    private func existingSessionDirectory(_ id: String) throws -> URL {
        let directory = try sessionDirectory(id)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MeetingSTTCoreError.sessionNotFound(id)
        }
        return directory
    }

    private func readMetadata(directory: URL, allowMissing: Bool) throws -> [String: Any] {
        let url = directory.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: url.path) else {
            if allowMissing { return [:] }
            throw MeetingSTTCoreError.sessionNotFound(directory.lastPathComponent)
        }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let dictionary = object as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return dictionary
        } catch {
            throw MeetingSTTCoreError.corruptMetadata(url, error)
        }
    }

    private func writeMetadata(_ metadata: [String: Any], directory: URL) throws {
        guard JSONSerialization.isValidJSONObject(metadata) else {
            throw MeetingSTTCoreError.recording("metadata에 JSON으로 저장할 수 없는 값이 있습니다.")
        }
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func makeSession(
        directory: URL,
        metadata: [String: Any],
        metadataError: String? = nil,
        includePendingAudio: Bool = false
    ) -> RecordingSession {
        let id = directory.lastPathComponent
        let audio = directory.appendingPathComponent("audio.wav")
        let audioExists = fileManager.fileExists(atPath: audio.path)
        let json = transcriptURL(metadata["transcript_json"], fallback: environment.outputsURL.appendingPathComponent("\(id).json"))
        let markdown = transcriptURL(metadata["transcript_md"], fallback: environment.outputsURL.appendingPathComponent("\(id).md"))
        let prompt = environment.outputsURL.appendingPathComponent("\(id).prompt.md")
        let byteCount = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return RecordingSession(
            id: id,
            directoryURL: directory,
            name: metadata["name"] as? String,
            status: metadata["status"] as? String ?? (audioExists ? "recorded" : "empty"),
            source: metadata["source"] as? String,
            deviceID: Self.int64(metadata["device"]).flatMap { AudioDeviceID(exactly: $0) },
            pid: Self.int64(metadata["pid"]).flatMap { pid_t(exactly: $0) },
            createdAt: metadata["created_at"] as? String ?? metadata["started_at"] as? String,
            startedAt: metadata["started_at"] as? String,
            stoppedAt: metadata["stopped_at"] as? String,
            duration: Self.double(metadata["duration_sec"]),
            bytes: byteCount,
            audioURL: audioExists || includePendingAudio ? audio : nil,
            transcriptJSONURL: json,
            transcriptMarkdownURL: markdown,
            promptURL: fileManager.fileExists(atPath: prompt.path) ? prompt : nil,
            transcribed: (metadata["transcribed"] as? Bool) == true || json != nil,
            metadataError: metadataError
        )
    }

    private func transcriptURL(_ metadataValue: Any?, fallback: URL) -> URL? {
        let candidate = (metadataValue as? String).map(URL.init(fileURLWithPath:)) ?? fallback
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return isInsideOutputs(resolved) && fileManager.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// 인자는 호출 전에 심링크가 해석돼 있어야 한다 — 모든 호출자가 그렇게 넘긴다.
    private func isInsideOutputs(_ resolved: URL) -> Bool {
        Self.hasPrefix(resolved.pathComponents, outputsComponents)
    }

    private func isInside(_ resolved: URL, parent resolvedParent: URL) -> Bool {
        Self.hasPrefix(resolved.pathComponents, resolvedParent.pathComponents)
    }

    private static func hasPrefix(_ child: [String], _ parent: [String]) -> Bool {
        child.count > parent.count && child.prefix(parent.count).elementsEqual(parent)
    }

    private func isValidWAV(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 44 else { return false }
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr, let audioFile else { return false }
        AudioFileClose(audioFile)
        return true
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: Date())
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
