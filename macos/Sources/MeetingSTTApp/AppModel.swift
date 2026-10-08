import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

enum CaptureSource: String, CaseIterable, Identifiable {
    case systemAndMic
    case device
    case system
    case app

    var id: Self { self }

    var title: String {
        switch self {
        case .systemAndMic: "System + Microphone"
        case .device: "Input device"
        case .system: "System audio"
        case .app: "App audio"
        }
    }

    var systemImage: String {
        switch self {
        case .systemAndMic: "mic.and.signal.meter"
        case .device: "mic"
        case .system: "speaker.wave.2"
        case .app: "macwindow"
        }
    }
}

enum Activity: Equatable {
    case idle
    case startingRecording
    case recording(sessionID: String, source: CaptureSource)
    case stoppingRecording
    case transcribing(sessionID: String)
    case generatingNotes(sessionID: String, promptOnly: Bool)
    case failed(message: String)
}

enum ResultKind: String, CaseIterable, Identifiable {
    case transcript
    case notes
    case prompt

    var id: Self { self }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .notes: "Markdown / Meeting notes"
        case .prompt: "AI summary prompt"
        }
    }

    var emptyDescription: String {
        switch self {
        case .transcript: "Transcribe a recording to see the results grouped by speaker."
        case .notes: "Generate meeting notes after transcription to see them here."
        case .prompt: "Generate an AI summary prompt after transcription to see it here."
        }
    }
}

private struct SessionResults: Equatable, Sendable {
    let transcript: String
    let notes: String
    let prompt: String

    static let empty = SessionResults(transcript: "", notes: "", prompt: "")
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var rootPath = ""

    @Published var captureSource: CaptureSource = .systemAndMic
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID?
    @Published private(set) var apps: [AppAudioSource] = []
    @Published var selectedAppPID: pid_t?

    @Published private(set) var sessions: [RecordingSession] = []
    @Published var selectedSessionID: String?

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var microphoneNotice: String?
    @Published private(set) var rmsLevel = 0.0
    @Published private(set) var recordedBytes: Int64 = 0

    @Published var context = ""
    @Published var speakerCount: Int?
    @Published var diarize = true
    @Published var project = ""

    @Published var resultKind: ResultKind = .transcript
    @Published private var results = SessionResults.empty
    @Published private(set) var logLines: [String] = []

    @Published private(set) var isPlaying = false
    @Published private(set) var playbackPosition: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0

    private var environment: ProjectEnvironment?
    private var sessionStore: SessionStore?
    private var processRunner: ProcessRunner?
    private var nativeRecorder: NativeRecorder?
    private let deviceRecorder = DeviceRecorder()
    private let completionNotifier = CompletionNotifier.shared

    private var didStart = false
    private var activeSessionID: String?
    private var activeSource: CaptureSource?
    private var activeAudioURL: URL?
    private var recordingStartedAt: Date?
    private var pausedSince = 0.0
    private var pauses: [ClosedRange<Double>] = []
    private var lastLevelAt = Date.distantPast
    private var recordingGeneration: UUID?
    private var workerGeneration: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    var selectedSession: RecordingSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var isBusy: Bool {
        switch activity {
        case .idle, .failed: false
        default: true
        }
    }

    var isRecordingOrStopping: Bool {
        switch activity {
        case .startingRecording, .recording, .stoppingRecording: true
        default: false
        }
    }

    var isStartingRecording: Bool {
        if case .startingRecording = activity { return true }
        return false
    }

    var canStopRecording: Bool {
        if case .recording = activity { return true }
        return false
    }

    var isStopping: Bool {
        if case .stoppingRecording = activity { return true }
        return false
    }

    var isWorkerRunning: Bool {
        switch activity {
        case .transcribing, .generatingNotes: true
        default: false
        }
    }

    var canStartRecording: Bool {
        guard activity == .idle, environment != nil else { return false }
        switch captureSource {
        case .device, .systemAndMic: return selectedDeviceID != nil
        case .system: return true
        case .app: return selectedAppPID != nil
        }
    }

    var canRunWorker: Bool {
        activity == .idle && processRunner != nil
    }

    var canGenerateNotes: Bool {
        canRunWorker && selectedSession?.transcriptJSONURL != nil
    }

    var requiresTerminationCleanup: Bool {
        activeSessionID != nil || workerGeneration != nil || isBusy
    }

    var activityDescription: String {
        switch activity {
        case .idle: "Ready"
        case .startingRecording: "Preparing to record…"
        case .recording: isPaused ? "Paused" : "Recording"
        case .stoppingRecording: "Saving recording…"
        case .transcribing: "Transcribing…"
        case .generatingNotes(_, let promptOnly): promptOnly ? "Generating prompt…" : "Generating notes…"
        case .failed: "Error"
        }
    }

    var workerDescription: String {
        switch activity {
        case .transcribing: "Transcribing your recording…"
        case .generatingNotes(_, let promptOnly): promptOnly ? "Creating an AI summary prompt." : "Creating meeting notes."
        default: "One transcription or notes task can run at a time."
        }
    }

    var currentResultText: String {
        switch resultKind {
        case .transcript: results.transcript
        case .notes: results.notes
        case .prompt: results.prompt
        }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            let environment = try ProjectEnvironment.resolve()
            self.environment = environment
            rootPath = environment.rootURL.path
            sessionStore = try SessionStore(environment: environment)
            processRunner = ProcessRunner(environment: environment)
            nativeRecorder = NativeRecorder(environment: environment)
            activity = .idle
            errorMessage = nil
            refreshDevices()
            refreshSessions()
            await refreshApps()
        } catch {
            didStart = false
            presentFailure("Could not prepare project", error)
        }
    }

    func refreshDevices() {
        do {
            devices = try DeviceRecorder.inputDevices()
            if !devices.contains(where: { $0.id == selectedDeviceID }) {
                if let defaultID = DeviceRecorder.defaultInputDeviceID(),
                   devices.contains(where: { $0.id == defaultID }) {
                    selectedDeviceID = defaultID
                } else {
                    selectedDeviceID = devices.first?.id
                }
            }
        } catch {
            presentError("Could not refresh input devices", error)
        }
    }

    func refreshApps() async {
        guard let nativeRecorder else { return }
        do {
            apps = try await nativeRecorder.listApps()
            if !apps.contains(where: { $0.pid == selectedAppPID }) {
                selectedAppPID = apps.first?.pid
            }
        } catch {
            presentError("Could not refresh app list", error)
        }
    }

    func refreshSessions(preferredID: String? = nil) {
        Task { await reloadSessions(preferredID: preferredID) }
    }

    /// 목록 한 번 읽는 데 세션 수만큼 metadata 읽기와 stat이 든다 — MainActor 밖에서 돌린다.
    func reloadSessions(preferredID: String? = nil) async {
        guard activeSessionID == nil, let sessionStore else { return }
        let previous = preferredID ?? selectedSessionID
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try sessionStore.list() }.value
            sessions = loaded
            selectedSessionID = loaded.contains(where: { $0.id == previous }) ? previous : loaded.first?.id
            await loadSelectedSession()
        } catch {
            presentError("Could not refresh recordings", error)
        }
    }

    /// 3시간 회의면 전사·회의록이 수십만 자다. 디코딩과 파일 읽기를 MainActor 밖으로 뺀다.
    func loadSelectedSession() async {
        stopPlayback()
        guard let session = selectedSession, let sessionStore else {
            results = .empty
            return
        }

        let id = session.id
        let hasTranscript = session.transcriptJSONURL != nil
        let markdownURL = session.transcriptMarkdownURL
        let promptURL = session.promptURL

        let (loaded, failures) = await Task.detached(priority: .userInitiated) { () -> (SessionResults, [String]) in
            var failures: [String] = []
            var transcript = ""
            var notes = ""
            var prompt = ""
            if hasTranscript {
                do {
                    let document = try sessionStore.loadTranscript(sessionID: id)
                    transcript = document.segments.map(Self.formatSegment).joined(separator: "\n")
                } catch {
                    failures.append("Could not load transcript: \(error.localizedDescription)")
                }
            }
            if let markdownURL {
                do {
                    notes = try String(contentsOf: markdownURL, encoding: .utf8)
                } catch {
                    failures.append("Could not load Markdown result: \(error.localizedDescription)")
                }
            }
            if let promptURL {
                do {
                    prompt = try String(contentsOf: promptURL, encoding: .utf8)
                } catch {
                    failures.append("Could not load AI summary prompt: \(error.localizedDescription)")
                }
            }
            return (SessionResults(transcript: transcript, notes: notes, prompt: prompt), failures)
        }.value

        // 읽는 사이 선택이 바뀌었으면 버린다 — 늦게 끝난 이전 세션이 새 선택을 덮어쓰지 않게.
        guard selectedSessionID == id else { return }
        if results != loaded { results = loaded }
        for failure in failures { presentMessage(failure) }
    }

    func startRecording() async {
        guard activity == .idle else {
            presentError("Could not start recording", MeetingSTTCoreError.processAlreadyRunning)
            return
        }
        guard let sessionStore, let nativeRecorder else {
            presentError("Could not start recording", MeetingSTTCoreError.projectRootNotFound([]))
            return
        }

        let deviceID: AudioDeviceID?
        let pid: pid_t?
        switch captureSource {
        case .device, .systemAndMic:
            guard let selectedDeviceID else {
                presentError("Could not start recording", MeetingSTTCoreError.recording("Select an input device."))
                return
            }
            deviceID = selectedDeviceID
            pid = nil
        case .app:
            guard let selectedAppPID else {
                presentError("Could not start recording", MeetingSTTCoreError.recording("Select an app to record."))
                return
            }
            deviceID = nil
            pid = selectedAppPID
        case .system:
            deviceID = nil
            pid = nil
        }

        activity = .startingRecording
        errorMessage = nil
        let generation = UUID()
        recordingGeneration = generation
        var createdSession: RecordingSession?

        do {
            if captureSource == .systemAndMic { _ = try RecordingMixer.executable() }
            if captureSource == .device || captureSource == .systemAndMic {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw MeetingSTTCoreError.recording("Allow Meeting STT in System Settings > Privacy & Security > Microphone.")
                }
            }
            let session = try sessionStore.create(source: captureSource.rawValue, device: deviceID, pid: pid)
            createdSession = session
            guard let audioURL = session.audioURL else {
                throw MeetingSTTCoreError.recording("Could not create the session audio path: \(session.id)")
            }
            activeSessionID = session.id
            activeSource = captureSource
            activeAudioURL = audioURL
            recordingStartedAt = Date()
            elapsed = 0
            rmsLevel = 0
            recordedBytes = 0
            lastLevelAt = .distantPast

            let onLevel: @Sendable (Double) -> Void = { [weak self] level in
                Task { @MainActor in self?.receiveLevel(level, generation: generation) }
            }
            let onMicrophoneChange: @Sendable (String?, Bool) -> Void = { [weak self] name, isSelected in
                Task { @MainActor in self?.microphoneChanged(to: name, isSelected: isSelected, generation: generation) }
            }

            switch captureSource {
            case .systemAndMic:
                let directory = audioURL.deletingLastPathComponent()
                try deviceRecorder.start(
                    deviceID: deviceID!,
                    outputURL: directory.appendingPathComponent("microphone.wav"),
                    onLevel: { _ in },
                    onDeviceChange: onMicrophoneChange
                )
                try await nativeRecorder.startSystem(
                    outputURL: directory.appendingPathComponent("system.wav"),
                    onLevel: onLevel,
                    onLog: logCallback(prefix: "apptap"),
                    onExit: nativeExitCallback(generation: generation)
                )
            case .device:
                try deviceRecorder.start(deviceID: deviceID!, outputURL: audioURL, onLevel: onLevel, onDeviceChange: onMicrophoneChange)
            case .app:
                try await nativeRecorder.startApp(
                    pid: pid!,
                    outputURL: audioURL,
                    onLevel: onLevel,
                    onLog: logCallback(prefix: "apptap"),
                    onExit: nativeExitCallback(generation: generation)
                )
            case .system:
                try await nativeRecorder.startSystem(
                    outputURL: audioURL,
                    onLevel: onLevel,
                    onLog: logCallback(prefix: "apptap"),
                    onExit: nativeExitCallback(generation: generation)
                )
            }

            guard recordingGeneration == generation else { return }
            activity = .recording(sessionID: session.id, source: captureSource)
            appendLog("Recording started: \(session.id) · \(captureSource.title)")
            startHeartbeat(generation: generation)
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            selectedSessionID = session.id
        } catch {
            _ = try? await nativeRecorder.stop()
            if deviceRecorder.isRecording { _ = try? deviceRecorder.stop() }
            if let session = createdSession {
                markRecordingError(sessionID: session.id, error: error)
            }
            clearRecordingRuntime()
            refreshSessions(preferredID: createdSession?.id)
            presentFailure("Could not start recording", error)
        }
    }

    /// 장치·탭·WAV는 그대로 두고 프레임만 버린다. 정지 구간은 결과 파일에서 빠진다.
    func togglePause() {
        guard case .recording(_, let source) = activity, let nativeRecorder else { return }
        let pausing = !isPaused
        do {
            // ponytail: 두 녹음기를 신호·플래그로 따로 멈춰 정지마다 트랙이 수 ms 어긋날 수 있다.
            // 문제가 되면 공유 host time 기준으로 양쪽을 게이트한다.
            if source != .device { try nativeRecorder.setPaused(pausing) }
            if source == .device || source == .systemAndMic { deviceRecorder.setPaused(pausing) }
        } catch {
            presentError(pausing ? "Could not pause recording" : "Could not resume recording", error)
            return
        }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        if pausing {
            pausedSince = now
        } else {
            pauses.append(pausedSince...now)
            recordingStartedAt = Date().addingTimeInterval(-elapsed)
        }
        isPaused = pausing
        appendLog(pausing ? "Recording paused" : "Recording resumed")
    }

    func stopRecording() async {
        guard case .recording = activity,
              let sessionID = activeSessionID,
              let source = activeSource,
              let audioURL = activeAudioURL,
              let sessionStore,
              let nativeRecorder
        else { return }

        activity = .stoppingRecording
        heartbeatTask?.cancel()
        heartbeatTask = nil

        do {
            let stats: RecordingStats
            switch source {
            case .systemAndMic:
                let microphone = try deviceRecorder.stop()
                let system = try await nativeRecorder.stop()
                if system.startedHostTime == nil { appendLog("No system audio was received; saving that track as silence.") }
                stats = try await RecordingMixer.mix(
                    directory: audioURL.deletingLastPathComponent(),
                    microphoneStart: microphone.startedHostTime,
                    systemStart: system.startedHostTime,
                    pauses: pauses
                )
            case .device: stats = try deviceRecorder.stop()
            case .app, .system: stats = try await nativeRecorder.stop()
            }
            try sessionStore.merge(
                sessionID: sessionID,
                fields: [
                    "status": .string("recorded"),
                    "stopped_at": .string(Self.timestamp()),
                    "duration_sec": .number(stats.duration),
                    "audio_path": .string(audioURL.path),
                    "audio_url": .string("/api/recordings/\(sessionID)/audio"),
                    "bytes": .integer(stats.bytes),
                ],
                removing: ["error"]
            )
            elapsed = stats.duration
            recordedBytes = stats.bytes
            rmsLevel = 0
            appendLog("Recording saved: \(sessionID) · \(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))")
            clearRecordingRuntime(keepMetrics: true)
            activity = .idle
            refreshSessions(preferredID: sessionID)
        } catch {
            _ = try? await nativeRecorder.stop()
            if deviceRecorder.isRecording { _ = try? deviceRecorder.stop() }
            markRecordingError(sessionID: sessionID, error: error)
            clearRecordingRuntime(keepMetrics: true)
            refreshSessions(preferredID: sessionID)
            presentFailure("Could not stop recording", error)
        }
    }

    func transcribe(sessionID: String) async {
        guard activity == .idle, let processRunner, let sessionStore, let environment else {
            presentError("Could not start transcription", MeetingSTTCoreError.processAlreadyRunning)
            return
        }
        guard let session = sessions.first(where: { $0.id == sessionID }), let audioURL = session.audioURL else {
            presentError("Could not start transcription", MeetingSTTCoreError.recording("No recording is available to transcribe."))
            return
        }
        await completionNotifier.requestAuthorizationIfNeeded()
        let notificationSessionTitle = sessionTitle(session)

        let generation = UUID()
        workerGeneration = generation
        activity = .transcribing(sessionID: sessionID)
        errorMessage = nil
        resultKind = .transcript
        appendLog("Start transcription: \(sessionID)")

        let jsonURL = environment.outputsURL.appendingPathComponent("\(sessionID).json")
        let markdownURL = environment.outputsURL.appendingPathComponent("\(sessionID).md")
        var arguments = ["-m", "meeting_stt", "transcribe", audioURL.path]
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty { arguments += ["--context", trimmedContext] }
        if let speakerCount { arguments += ["--num-speakers", String(speakerCount)] }
        if !diarize { arguments.append("--no-diarize") }
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty { arguments += ["--project", trimmedProject] }

        do {
            _ = try await processRunner.runPython(
                arguments: arguments,
                expectedFiles: [jsonURL, markdownURL],
                onStdout: logCallback(prefix: "python"),
                onStderr: logCallback(prefix: "python Error")
            )
            guard workerGeneration == generation else { return }
            _ = try sessionStore.loadTranscript(sessionID: sessionID)
            try sessionStore.merge(
                sessionID: sessionID,
                fields: [
                    "status": .string("transcribed"),
                    "transcribed": .bool(true),
                    "transcribed_at": .string(Self.timestamp()),
                    "transcript_json": .string(jsonURL.path),
                    "transcript_md": .string(markdownURL.path),
                ]
            )
            let preferredID = selectedSessionID
            workerGeneration = nil
            activity = .idle
            appendLog("Transcription complete: \(jsonURL.path)")
            if preferredID == sessionID { resultKind = .transcript }
            refreshSessions(preferredID: preferredID)
            await completionNotifier.notifyTranscriptionCompleted(
                sessionTitle: notificationSessionTitle,
                sessionID: sessionID
            )
        } catch {
            guard workerGeneration == generation else { return }
            workerGeneration = nil
            presentFailure("Transcription failed", error)
        }
    }

    func generateNotes(promptOnly: Bool, ai: Bool = false) async {
        guard activity == .idle, let processRunner, let environment, let session = selectedSession,
              let transcriptURL = session.transcriptJSONURL
        else {
            presentError("Could not generate notes", MeetingSTTCoreError.recording("Select a transcript first."))
            return
        }

        let generation = UUID()
        workerGeneration = generation
        activity = .generatingNotes(sessionID: session.id, promptOnly: promptOnly)
        errorMessage = nil
        let outputURL = environment.outputsURL.appendingPathComponent(
            promptOnly ? "\(session.id).prompt.md" : "\(session.id).md"
        )
        var arguments = ["-m", "meeting_stt", "notes", transcriptURL.path]
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty { arguments += ["--project", trimmedProject] }
        if promptOnly { arguments.append("--prompt-only") }
        if ai { arguments.append("--ai") }
        appendLog(promptOnly ? "Generating AI summary prompt: \(session.id)"
                  : ai ? "Generating AI notes(claude CLI): \(session.id)"
                  : "Generating meeting notes: \(session.id)")

        do {
            _ = try await processRunner.runPython(
                arguments: arguments,
                expectedFiles: [outputURL],
                onStdout: logCallback(prefix: "python"),
                onStderr: logCallback(prefix: "python Error")
            )
            guard workerGeneration == generation else { return }
            _ = try String(contentsOf: outputURL, encoding: .utf8)
            let preferredID = selectedSessionID
            workerGeneration = nil
            activity = .idle
            appendLog("Created: \(outputURL.path)")
            if preferredID == session.id { resultKind = promptOnly ? .prompt : .notes }
            refreshSessions(preferredID: preferredID)
        } catch {
            guard workerGeneration == generation else { return }
            workerGeneration = nil
            presentFailure(promptOnly ? "Could not generate AI summary prompt" : "Could not generate notes", error)
        }
    }

    func cancelWorker() async {
        guard isWorkerRunning, let processRunner else { return }
        workerGeneration = nil
        appendLog("Cancellation requested")
        await processRunner.cancel()
        activity = .idle
        appendLog("Task cancelled. Partial transcripts have been preserved.")
    }

    func renameSession(id: String, name: String) {
        guard let sessionStore else { return }
        do {
            try sessionStore.rename(sessionID: id, name: name)
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[index].name = trimmed.isEmpty ? nil : trimmed
        } catch {
            presentError("Could not rename session", error)
        }
    }

    func deleteSession(id: String) {
        guard activity == .idle else {
            presentError("Could not delete session", MeetingSTTCoreError.processAlreadyRunning)
            return
        }
        guard let sessionStore else {
            presentError("Could not delete session", MeetingSTTCoreError.recording("The project is not ready."))
            return
        }
        do {
            let result = try sessionStore.delete(sessionID: id, activeSessionID: activeSessionID)
            if selectedSessionID == id {
                stopPlayback()
                results = .empty
            }
            refreshSessions()
            if !result.errors.isEmpty {
                errorMessage = "The session was deleted, but some result files could not be removed:\n\(result.errors.joined(separator: "\n"))"
            }
        } catch {
            presentError("Could not delete session", error)
        }
    }

    func togglePlayback() {
        guard let audioURL = selectedSession?.audioURL else { return }
        do {
            if audioPlayer == nil {
                let player = try AVAudioPlayer(contentsOf: audioURL)
                player.prepareToPlay()
                audioPlayer = player
                playbackDuration = player.duration
            }
            guard let audioPlayer else { return }
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                isPlaying = false
                playbackTask?.cancel()
            } else {
                guard audioPlayer.play() else {
                    throw MeetingSTTCoreError.recording("Could not start playback: \(audioURL.path)")
                }
                isPlaying = true
                startPlaybackHeartbeat()
            }
        } catch {
            presentError("Could not play recording", error)
        }
    }

    func seekPlayback(to position: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = min(max(position, 0), audioPlayer.duration)
        playbackPosition = audioPlayer.currentTime
    }

    func copyCurrentResult() {
        guard !currentResultText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(currentResultText, forType: .string) else {
            presentError("Could not copy result", MeetingSTTCoreError.recording("Could not write text to the clipboard."))
            return
        }
        appendLog("Copied the current result to the clipboard.")
    }

    func dismissError() {
        errorMessage = nil
        if case .failed = activity { activity = .idle }
        if environment == nil { Task { await start() } }
    }

    func sessionTitle(_ session: RecordingSession) -> String {
        if let name = session.name, !name.isEmpty { return name }
        return session.createdAt ?? session.id
    }

    func sessionStatus(_ session: RecordingSession) -> String {
        switch session.status {
        case "recording": "Recording"
        case "recorded": "Recording saved"
        case "transcribed": "Transcription complete"
        case "error": "Error"
        default: session.status
        }
    }

    func deviceTitle(_ device: AudioInputDevice) -> String {
        "\(device.name) · \(device.channels)ch · \(device.sampleRate.formatted(.number.precision(.fractionLength(0)))) Hz"
    }

    func appTitle(_ app: AppAudioSource) -> String {
        "\(app.name) · PID \(app.pid)"
    }

    func shutdown() async {
        while isStopping || activity == .startingRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isWorkerRunning {
            await cancelWorker()
        }
        if case .recording = activity {
            await stopRecording()
        } else if activeSessionID != nil {
            nativeRecorder?.cancel()
            if deviceRecorder.isRecording { _ = try? deviceRecorder.stop() }
            if let activeSessionID {
                markRecordingError(
                    sessionID: activeSessionID,
                    error: MeetingSTTCoreError.recording("Could not finalize the recording while quitting.")
                )
            }
            clearRecordingRuntime()
        }
        stopPlayback()
    }

    private func receiveLevel(_ level: Double, generation: UUID) {
        guard recordingGeneration == generation else { return }
        rmsLevel = Self.visualLevel(forRMS: activeSource == .systemAndMic ? max(level, deviceRecorder.level) : level)
        lastLevelAt = Date()
    }

    /// 녹음은 DeviceRecorder가 알아서 이어 간다. 여기서는 사용자가 알 수 있게만 한다.
    private func microphoneChanged(to name: String?, isSelected: Bool, generation: UUID) {
        guard recordingGeneration == generation else { return }
        if isSelected {
            microphoneNotice = nil
            appendLog("Microphone restored: \(name ?? "")")
        } else if let name {
            microphoneNotice = "The selected microphone disconnected, so recording continues from \(name). It switches back when the microphone reconnects."
            appendLog("Microphone switched: \(name)")
        } else {
            microphoneNotice = "The microphone disconnected. Its track continues as silence until an input device reconnects."
            appendLog("Microphone disconnected: no input device is available.")
        }
    }

    private func startHeartbeat(generation: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.recordingGeneration == generation else { return }
                if !self.isPaused, let startedAt = self.recordingStartedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
                if Date().timeIntervalSince(self.lastLevelAt) > 0.5 { self.rmsLevel = 0 }
                if let audioURL = self.activeAudioURL {
                    let urls = self.activeSource == .systemAndMic
                        ? ["microphone.wav", "system.wav"].map { audioURL.deletingLastPathComponent().appendingPathComponent($0) }
                        : [audioURL]
                    self.recordedBytes = urls.reduce(0) { total, url in
                        total + (((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0)
                    }
                }
            }
        }
    }

    private func startPlaybackHeartbeat() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let player = self.audioPlayer else { return }
                self.playbackPosition = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if isPlaying { isPlaying = false }
        if playbackPosition != 0 { playbackPosition = 0 }
        if playbackDuration != 0 { playbackDuration = 0 }
    }

    private func nativeExitCallback(generation: UUID) -> @Sendable (Result<ProcessResult, Error>) -> Void {
        { [weak self] result in
            Task { @MainActor in await self?.nativeRecorderExited(result, generation: generation) }
        }
    }

    private func nativeRecorderExited(_ result: Result<ProcessResult, Error>, generation: UUID) async {
        guard recordingGeneration == generation, case .recording = activity, let sessionID = activeSessionID else { return }
        _ = try? await nativeRecorder?.stop()
        if deviceRecorder.isRecording { _ = try? deviceRecorder.stop() }
        let error: Error
        switch result {
        case .success(let processResult):
            if processResult.exitCode == 0 {
                error = MeetingSTTCoreError.recording(
                    processResult.stderr.isEmpty
                        ? "The audio capture process exited unexpectedly."
                        : processResult.stderr
                )
            } else {
                error = MeetingSTTCoreError.processFailed(
                    executable: environment?.appTapURL.path ?? "native/apptap",
                    status: processResult.exitCode,
                    stderr: processResult.stderr
                )
            }
        case .failure(let processError):
            error = processError
        }
        markRecordingError(sessionID: sessionID, error: error)
        clearRecordingRuntime()
        refreshSessions(preferredID: sessionID)
        presentFailure("Recording interrupted", error)
    }

    private func logCallback(prefix: String) -> @Sendable (String) -> Void {
        { [weak self] line in
            Task { @MainActor in self?.appendLog("[\(prefix)] \(line)") }
        }
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func markRecordingError(sessionID: String, error: Error) {
        guard let sessionStore else {
            appendLog("Could not save error metadata: The project is not ready.")
            return
        }
        do {
            try sessionStore.merge(
                sessionID: sessionID,
                fields: [
                    "status": .string("error"),
                    "error": .string(error.localizedDescription),
                    "stopped_at": .string(Self.timestamp()),
                    "bytes": .integer(recordedBytes),
                ]
            )
        } catch {
            appendLog("Could not save error metadata: \(error.localizedDescription)")
        }
    }

    private func clearRecordingRuntime(keepMetrics: Bool = false) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        recordingGeneration = nil
        activeSessionID = nil
        activeSource = nil
        activeAudioURL = nil
        recordingStartedAt = nil
        isPaused = false
        microphoneNotice = nil
        pauses = []
        lastLevelAt = .distantPast
        rmsLevel = 0
        if !keepMetrics {
            elapsed = 0
            recordedBytes = 0
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        presentMessage("\(title): \(error.localizedDescription)")
    }

    private func presentMessage(_ message: String) {
        errorMessage = message
        appendLog(message)
    }

    private func presentFailure(_ title: String, _ error: Error) {
        let message = "\(title): \(error.localizedDescription)"
        activity = .failed(message: message)
        errorMessage = message
        appendLog(message)
    }

    // Map -60...0 dBFS to 0...1 so normal speech is visible on a linear progress bar.
    static func visualLevel(forRMS level: Double) -> Double {
        guard level.isFinite, level > 0 else { return 0 }
        let decibels = 20 * log10(min(level, 1))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: Date())
    }

    private nonisolated static func formatSegment(_ segment: TranscriptSegment) -> String {
        "[\(segment.speaker)] \(clock(segment.start))~\(clock(segment.end)): \(segment.text)"
    }

    private nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
    }
}
