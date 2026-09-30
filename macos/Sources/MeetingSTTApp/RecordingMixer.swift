import AVFoundation
import Foundation

/// Preserve both source tracks; publish audio.wav only after a successful mix.
enum RecordingMixer {
    static func executable() throws -> URL {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MeetingSTTCoreError.recording("입출력 녹음을 합치려면 ffmpeg가 필요합니다. brew install ffmpeg로 설치하세요.")
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
            throw MeetingSTTCoreError.recording("녹음 동기화 시각이 없습니다. native/apptap을 다시 빌드하세요. 원본 microphone.wav와 system.wav는 보존했습니다.")
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
            throw MeetingSTTCoreError.recording("녹음 합치기 실패. 원본 트랙은 보존했습니다. \(result.stderr)")
        }
        let file = try AVAudioFile(forReading: temporary)
        guard file.length > 0 else { throw MeetingSTTCoreError.recording("합친 녹음 파일이 비어 있습니다.") }
        let duration = Double(file.length) / file.fileFormat.sampleRate
        try FileManager.default.moveItem(at: temporary, to: output)
        let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        return RecordingStats(duration: duration, bytes: bytes)
    }
}
