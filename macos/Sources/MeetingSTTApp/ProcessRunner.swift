import AudioToolbox
import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public struct AppAudioSource: Codable, Identifiable, Equatable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String
    public var id: pid_t { pid }
}

public final class ProcessRunner {
    public let environment: ProjectEnvironment
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public convenience init(rootURL: URL) throws {
        try self.init(environment: ProjectEnvironment(rootURL: rootURL))
    }

    public init(environment: ProjectEnvironment) {
        self.environment = environment
    }

    public func runPython(
        arguments: [String],
        expectedFiles: [URL] = [],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        let child = try reserveProcess()
        defer { releaseProcess(child) }
        var inherited = ProcessInfo.processInfo.environment
        inherited["PYTHONUNBUFFERED"] = "1"
        let result = try await ProcessExecution.run(
            process: child,
            executable: environment.pythonURL,
            arguments: arguments,
            currentDirectory: environment.rootURL,
            environment: inherited,
            onStdout: onStdout,
            onStderr: onStderr
        )
        if lock.withLock({ cancelled }) { throw CancellationError() }
        guard result.exitCode == 0 else {
            throw MeetingSTTCoreError.processFailed(
                executable: environment.pythonURL.path,
                status: result.exitCode,
                stderr: result.stderr
            )
        }
        for url in expectedFiles where !FileManager.default.fileExists(atPath: url.path) {
            throw MeetingSTTCoreError.missingOutput(url)
        }
        return result
    }

    public func cancel() async {
        guard let child = lock.withLock({
            cancelled = process != nil
            return process
        }), child.isRunning else { return }
        kill(child.processIdentifier, SIGINT)
        if await waitForExit(child, seconds: 5) { return }
        child.terminate()
        if await waitForExit(child, seconds: 2) { return }
        kill(child.processIdentifier, SIGKILL)
    }

    private func reserveProcess() throws -> Process {
        try lock.withLock {
            guard process == nil else { throw MeetingSTTCoreError.processAlreadyRunning }
            let child = Process()
            process = child
            cancelled = false
            return child
        }
    }

    private func releaseProcess(_ child: Process) {
        lock.withLock {
            if process === child { process = nil }
        }
    }
}

public final class NativeRecorder {
    public let environment: ProjectEnvironment
    private let lock = NSLock()
    private var active: NativeRecording?

    public convenience init(rootURL: URL) throws {
        try self.init(environment: ProjectEnvironment(rootURL: rootURL))
    }

    public init(environment: ProjectEnvironment) {
        self.environment = environment
    }

    public func listApps() async throws -> [AppAudioSource] {
        let result = try await ProcessExecution.run(
            process: Process(),
            executable: environment.appTapURL,
            arguments: ["list"],
            currentDirectory: environment.rootURL,
            environment: ProcessInfo.processInfo.environment
        )
        guard result.exitCode == 0 else {
            throw MeetingSTTCoreError.processFailed(
                executable: environment.appTapURL.path,
                status: result.exitCode,
                stderr: result.stderr
            )
        }
        do {
            return try JSONDecoder().decode([AppAudioSource].self, from: Data(result.stdout.utf8))
        } catch {
            throw MeetingSTTCoreError.processLaunch("Could not parse apptap list JSON: \(error.localizedDescription)")
        }
    }

    public func startApp(
        pid: pid_t,
        outputURL: URL,
        onLevel: @escaping @Sendable (Double) -> Void,
        onLog: @escaping @Sendable (String) -> Void = { _ in },
        onExit: @escaping @Sendable (Result<ProcessResult, Error>) -> Void = { _ in }
    ) async throws {
        try await start(
            arguments: ["record", "--pid", String(pid), "--out", outputURL.path],
            outputURL: outputURL,
            onLevel: onLevel,
            onLog: onLog,
            onExit: onExit
        )
    }

    public func startSystem(
        outputURL: URL,
        onLevel: @escaping @Sendable (Double) -> Void,
        onLog: @escaping @Sendable (String) -> Void = { _ in },
        onExit: @escaping @Sendable (Result<ProcessResult, Error>) -> Void = { _ in }
    ) async throws {
        try await start(
            arguments: ["record-system", "--out", outputURL.path],
            outputURL: outputURL,
            onLevel: onLevel,
            onLog: onLog,
            onExit: onExit
        )
    }

    public func stop() async throws -> RecordingStats {
        guard let recording = lock.withLock({ active }) else { throw MeetingSTTCoreError.noProcessRunning }
        let child = recording.process
        if child.isRunning { child.terminate() }
        let exited = await waitForExit(child, seconds: 5)
        if !exited {
            kill(child.processIdentifier, SIGKILL)
            _ = await waitForExit(child, seconds: 1)
        }
        let result = await recording.result()
        lock.withLock {
            if active === recording { active = nil }
        }
        guard exited, result.exitCode == 0 else {
            throw MeetingSTTCoreError.processFailed(
                executable: environment.appTapURL.path,
                status: result.exitCode,
                stderr: result.stderr.isEmpty && !exited ? "WAV finalization did not finish within 5 seconds of SIGTERM." : result.stderr
            )
        }
        let bytes = try Self.validateWAV(recording.outputURL)
        return RecordingStats(duration: Date().timeIntervalSince(recording.startedAt), bytes: bytes, startedHostTime: recording.firstHostTime)
    }

    public func cancel() {
        guard let child = lock.withLock({ active?.process }), child.isRunning else { return }
        child.terminate()
    }

    private func start(
        arguments: [String],
        outputURL: URL,
        onLevel: @escaping @Sendable (Double) -> Void,
        onLog: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Result<ProcessResult, Error>) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let child = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = environment.appTapURL
        child.arguments = arguments
        child.currentDirectoryURL = environment.rootURL
        child.environment = ProcessInfo.processInfo.environment
        child.standardOutput = stdout
        child.standardError = stderr
        let recording = NativeRecording(
            process: child,
            outputURL: outputURL,
            stdout: stdout,
            stderr: stderr,
            onLevel: onLevel,
            onLog: onLog,
            onExit: onExit
        )
        try lock.withLock {
            guard active == nil else { throw MeetingSTTCoreError.processAlreadyRunning }
            active = recording
        }
        do {
            try child.run()
        } catch {
            lock.withLock { active = nil }
            throw MeetingSTTCoreError.processLaunch(error.localizedDescription)
        }
        recording.beginDraining()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if recording.hasStarted { return }
            if !child.isRunning {
                let result = await recording.result()
                lock.withLock { active = nil }
                throw MeetingSTTCoreError.processFailed(
                    executable: environment.appTapURL.path,
                    status: result.exitCode,
                    stderr: result.stderr
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if child.isRunning {
            // Some systems buffer stderr. A process that survives the startup window is considered started.
            return
        }
        let result = await recording.result()
        lock.withLock { active = nil }
        throw MeetingSTTCoreError.processFailed(
            executable: environment.appTapURL.path,
            status: result.exitCode,
            stderr: result.stderr
        )
    }

    private static func validateWAV(_ url: URL) throws -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber,
              number.int64Value > 44
        else {
            throw MeetingSTTCoreError.recording("The finalized WAV file is missing or empty: \(url.path)")
        }
        var audioFile: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard status == noErr, let audioFile else {
            throw MeetingSTTCoreError.recording("Could not open the finalized WAV (OSStatus \(status)): \(url.path)")
        }
        AudioFileClose(audioFile)
        return number.int64Value
    }
}

private final class NativeRecording: @unchecked Sendable {
    let process: Process
    let outputURL: URL
    let startedAt = Date()
    private let stdout: Pipe
    private let stderr: Pipe
    private let stdoutBuffer = BoundedTextBuffer()
    private let stderrBuffer = BoundedTextBuffer()
    private let group = DispatchGroup()
    private let stateLock = NSLock()
    private let onLevel: @Sendable (Double) -> Void
    private let onLog: @Sendable (String) -> Void
    private let onExit: @Sendable (Result<ProcessResult, Error>) -> Void
    private var audioStart: Double?
    var firstHostTime: Double? { stateLock.withLock { audioStart } }
    private var started = false
    private var draining = false

    var hasStarted: Bool { stateLock.withLock { started } }

    init(
        process: Process,
        outputURL: URL,
        stdout: Pipe,
        stderr: Pipe,
        onLevel: @escaping @Sendable (Double) -> Void,
        onLog: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Result<ProcessResult, Error>) -> Void
    ) {
        self.process = process
        self.outputURL = outputURL
        self.stdout = stdout
        self.stderr = stderr
        self.onLevel = onLevel
        self.onLog = onLog
        self.onExit = onExit
    }

    func beginDraining() {
        guard stateLock.withLock({
            if draining { return false }
            draining = true
            return true
        }) else { return }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            drain(self.stdout.fileHandleForReading, buffer: self.stdoutBuffer) { [self] line in
                if line.hasPrefix("START_HOST "), let value = Double(line.dropFirst(11)) {
                    self.stateLock.withLock { self.audioStart = value }
                } else if line.hasPrefix("LEVEL "), let value = Double(line.dropFirst(6)) {
                    self.onLevel(value)
                } else if !line.isEmpty {
                    self.onLog(line)
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            drain(self.stderr.fileHandleForReading, buffer: self.stderrBuffer) { [self] line in
                if line.contains("Recording started") { self.stateLock.withLock { self.started = true } }
                if !line.isEmpty { self.onLog(line) }
            }
            group.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            process.waitUntilExit()
            group.wait()
            let result = ProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdoutBuffer.text,
                stderr: stderrBuffer.text
            )
            if result.exitCode == 0 {
                onExit(.success(result))
            } else {
                onExit(.failure(MeetingSTTCoreError.processFailed(
                    executable: process.executableURL?.path ?? "apptap",
                    status: result.exitCode,
                    stderr: result.stderr
                )))
            }
        }
    }

    func result() async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdoutBuffer.text,
                    stderr: stderrBuffer.text
                ))
            }
        }
    }
}

enum ProcessExecution {
    static func run(
        process: Process,
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw MeetingSTTCoreError.processLaunch("\(executable.path): \(error.localizedDescription)")
        }

        return await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let stdoutBuffer = BoundedTextBuffer()
            let stderrBuffer = BoundedTextBuffer()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                drain(stdout.fileHandleForReading, buffer: stdoutBuffer, onLine: onStdout)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                drain(stderr.fileHandleForReading, buffer: stderrBuffer, onLine: onStderr)
                group.leave()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdoutBuffer.text,
                    stderr: stderrBuffer.text
                ))
            }
        }
    }
}

private final class BoundedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 1_048_576

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

private func drain(
    _ handle: FileHandle,
    buffer: BoundedTextBuffer,
    onLine: @escaping @Sendable (String) -> Void
) {
    var pending = Data()
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newline]
            pending.removeSubrange(...newline)
            onLine(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
    }
    if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
}

private func waitForExit(_ process: Process, seconds: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return !process.isRunning
}
