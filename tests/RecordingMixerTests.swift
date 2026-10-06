import AVFoundation

@main
struct RecordingMixerTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let tests = RecordingMixerTests()
        try await tests.testMixResamplesAlignsAndPreservesBothTracks()
        try await tests.testSilentSystemKeepsMicrophone()
        try await tests.testMissingTimestampDoesNotPublishAudio()
        try await tests.testFailedMixPreservesOriginal()
        try await tests.testPauseBeforeSystemStartDoesNotDelaySystem()
        print("PASS: resampling, both start orders, overlap, tail, source preservation, missing timestamp, failed mix, pause alignment")
        if CommandLine.arguments.contains("--live") { try await tests.live() }
    }
    func live() async throws {
        let environment = try ProjectEnvironment(rootURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let store = try SessionStore(environment: environment)
        guard let device = DeviceRecorder.defaultInputDeviceID() else { fatalError("No default microphone") }
        let session = try store.create(source: "systemAndMic", device: device)
        let directory = session.audioURL!.deletingLastPathComponent()
        let mic = DeviceRecorder()
        let system = NativeRecorder(environment: environment)
        do {
            try mic.start(deviceID: device, outputURL: directory.appendingPathComponent("microphone.wav"), onLevel: { _ in })
            try await system.startSystem(outputURL: directory.appendingPathComponent("system.wav"), onLevel: { _ in }, onLog: { print($0) })
            let toneURL = directory.appendingPathComponent("test-tone.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 4)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.04 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
            do { let file = try AVAudioFile(forWriting: toneURL, settings: format.settings); try file.write(from: buffer) }
            let player = try AVAudioPlayer(contentsOf: toneURL)
            player.play()
            print("LIVE: recording system + microphone with a quiet test tone for 5 seconds")
            try await Task.sleep(nanoseconds: 5_000_000_000)
            player.stop()
            let m = try mic.stop()
            let s = try await system.stop()
            print("HOST microphone=\(String(describing: m.startedHostTime)) system=\(String(describing: s.startedHostTime))")
            let stats = try await RecordingMixer.mix(directory: directory, microphoneStart: m.startedHostTime, systemStart: s.startedHostTime)
            try store.merge(sessionID: session.id, fields: ["status": .string("recorded"), "duration_sec": .number(stats.duration), "bytes": .integer(stats.bytes), "name": .string("System + microphone recording test")])
            print("LIVE PASS: \(directory.path), \(stats.duration)s, \(stats.bytes) bytes")
        } catch {
            if mic.isRecording { _ = try? mic.stop() }
            _ = try? await system.stop()
            try? store.merge(sessionID: session.id, fields: ["status": .string("error"), "error": .string(error.localizedDescription)])
            throw error
        }
    }

    private func track(_ url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double, value: Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = value }
        }
        try file.write(from: buffer)
    }

    func testMixResamplesAlignsAndPreservesBothTracks() async throws {
        for micFirst in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try track(directory.appendingPathComponent("microphone.wav"), rate: 44_100, channels: 1, seconds: 1, value: 0.2)
            try track(directory.appendingPathComponent("system.wav"), rate: 48_000, channels: 2, seconds: 0.5, value: 0.4)
            let stats = try await RecordingMixer.mix(directory: directory, microphoneStart: micFirst ? 10 : 10.25, systemStart: micFirst ? 10.25 : 10)
            expectEqual(stats.duration, micFirst ? 1 : 1.25, accuracy: 0.001)
            let file = try AVAudioFile(forReading: directory.appendingPathComponent("audio.wav"))
            expectEqual(file.processingFormat.channelCount, 1)
            expectEqual(file.processingFormat.sampleRate, 48_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = buffer.floatChannelData![0]
            // First-only, overlapping, and microphone-only portions must all survive.
            expectEqual(samples[4_800], micFirst ? 0.1 : 0.2, accuracy: 0.005)
            expectEqual(samples[19_200], 0.3, accuracy: 0.005)
            expectEqual(samples[43_200], 0.1, accuracy: 0.005)
            for name in ["microphone.wav", "system.wav"] {
                assert(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
            }
        }
    }

    func testSilentSystemKeepsMicrophone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try track(directory.appendingPathComponent("microphone.wav"), rate: 48_000, channels: 1, seconds: 1, value: 0.2)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do { _ = try AVAudioFile(forWriting: directory.appendingPathComponent("system.wav"), settings: format.settings) }
        let stats = try await RecordingMixer.mix(directory: directory, microphoneStart: 10, systemStart: nil)
        expectEqual(stats.duration, 1, accuracy: 0.001)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("audio.wav"))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        try file.read(into: buffer)
        expectEqual(buffer.floatChannelData![0][4_800], 0.1, accuracy: 0.005)
    }

    func testPauseBeforeSystemStartDoesNotDelaySystem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try track(directory.appendingPathComponent("microphone.wav"), rate: 48_000, channels: 1, seconds: 1, value: 0.2)
        try track(directory.appendingPathComponent("system.wav"), rate: 48_000, channels: 2, seconds: 0.25, value: 0.4)
        // Mic ran 10...10.5, paused for 60 s, ran 70.5...71; system audio first arrived at 70.75.
        let stats = try await RecordingMixer.mix(directory: directory, microphoneStart: 10, systemStart: 70.75, pauses: [10.5...70.5])
        expectEqual(stats.duration, 1, accuracy: 0.001)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("audio.wav"))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        expectEqual(buffer.floatChannelData![0][4_800], 0.1, accuracy: 0.005)
        expectEqual(buffer.floatChannelData![0][42_000], 0.3, accuracy: 0.005)
    }

    func testMissingTimestampDoesNotPublishAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try track(directory.appendingPathComponent("microphone.wav"), rate: 48_000, channels: 1, seconds: 0.1, value: 0.2)
        try track(directory.appendingPathComponent("system.wav"), rate: 48_000, channels: 2, seconds: 0.1, value: 0.2)
        do {
            _ = try await RecordingMixer.mix(directory: directory, microphoneStart: nil, systemStart: 1)
            fatalError("Missing timestamps must fail")
        } catch {
            assert(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.wav").path))
        }
    }

    func testFailedMixPreservesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = directory.appendingPathComponent("microphone.wav")
        try track(microphone, rate: 48_000, channels: 1, seconds: 0.1, value: 0.2)
        let original = try Data(contentsOf: microphone)
        do {
            _ = try await RecordingMixer.mix(directory: directory, microphoneStart: 1, systemStart: 1)
            fatalError("Missing system track must fail")
        } catch {
            expectEqual(try Data(contentsOf: microphone), original)
            assert(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.wav").path))
        }
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T) { assert(lhs == rhs, "Expected \(rhs), got \(lhs)") }
private func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double) { assert(abs(lhs - rhs) <= accuracy, "Expected \(rhs), got \(lhs)") }
private func expectEqual(_ lhs: Float, _ rhs: Float, accuracy: Float) { assert(abs(lhs - rhs) <= accuracy, "Expected \(rhs), got \(lhs)") }
