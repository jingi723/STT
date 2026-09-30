import AVFoundation
import Foundation

/// Preserve both source tracks; publish audio.wav only after a successful mix.
enum RecordingMixer {
    static func executable() throws -> URL {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MeetingSTTCoreError.recording("Combining microphone and system audio requires ffmpeg. Install it with brew install ffmpeg.")
        }
        return URL(fileURLWithPath: path)
    }

    static func mix(directory: URL, microphoneStart: Double?, systemStart: Double?) async throws -> RecordingStats {
        let systemURL = directory.appendingPathComponent("system.wav")
        let microphoneURL = directory.appendingPathComponent("microphone.wav")
        let systemFile = try AVAudioFile(forReading: systemURL)
        let microphoneFile = try AVAudioFile(forReading: microphoneURL)
        // A global tap can receive no callbacks when nothing plays during the session.
        // Represent that track as silence while keeping the microphone recording usable.
        let silentSystem = systemFile.length == 0
        let systemStart = silentSystem ? microphoneStart : systemStart
        guard let microphoneStart, let systemStart,
              microphoneStart.isFinite, systemStart.isFinite else {
            throw MeetingSTTCoreError.recording("Recording timestamps are missing. Rebuild native/apptap. The original microphone.wav and system.wav have been preserved.")
        }
        let origin = min(microphoneStart, systemStart)
        let micDelay = Int(((microphoneStart - origin) * 48_000).rounded())
        let systemDelay = Int(((systemStart - origin) * 48_000).rounded())
        let temporary = directory.appendingPathComponent("audio-mixing.wav")
        let output = directory.appendingPathComponent("audio.wav")
        // Equal fixed gains avoid clipping and volume jumps when one track ends.
        let filter = "[0:a]aresample=48000,aformat=channel_layouts=mono,adelay=\(micDelay)S:all=1[m];"
            + "[1:a]aresample=48000,pan=mono|c0=0.5*c0+0.5*c1,adelay=\(systemDelay)S:all=1[s];"
            + "[m][s]amix=inputs=2:duration=longest:normalize=0,volume=0.5[out]"
        let systemInput = silentSystem
            ? ["-f", "lavfi", "-t", String(Double(microphoneFile.length) / microphoneFile.fileFormat.sampleRate), "-i", "anullsrc=r=48000:cl=stereo"]
            : ["-i", systemURL.path]
        let result = try await ProcessExecution.run(
            process: Process(), executable: executable(),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", microphoneURL.path] + systemInput + ["-filter_complex", filter, "-map", "[out]", "-c:a", "pcm_s16le", temporary.path],
            currentDirectory: directory, environment: ProcessInfo.processInfo.environment
        )
        guard result.exitCode == 0 else {
            throw MeetingSTTCoreError.recording("Could not combine the recordings. The original tracks have been preserved. \(result.stderr)")
        }
        let file = try AVAudioFile(forReading: temporary)
        guard file.length > 0 else { throw MeetingSTTCoreError.recording("The combined recording is empty.") }
        let duration = Double(file.length) / file.fileFormat.sampleRate
        try FileManager.default.moveItem(at: temporary, to: output)
        let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        return RecordingStats(duration: duration, bytes: bytes)
    }
}
