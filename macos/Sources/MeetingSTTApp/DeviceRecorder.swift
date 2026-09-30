import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let channels: UInt32
    public let sampleRate: Double
}

public struct RecordingStats: Equatable, Sendable {
    public let duration: TimeInterval
    public let bytes: Int64
    public var startedHostTime: TimeInterval? = nil
}

public final class DeviceRecorder {
    private let stateLock = NSLock()
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: ExtAudioFileRef?
    private var outputURL: URL?
    private var sampleRate = 0.0
    private var framesWritten: UInt64 = 0
    private var firstHostTime: TimeInterval?
    private var sumSquares = 0.0
    private var sampleCount: UInt64 = 0
    private var lastSamplesAt = Date.distantPast
    private var lastLevel = 0.0
    private var levelTimer: DispatchSourceTimer?
    private var inputFormat = AudioStreamBasicDescription()
    private var recording = false
    private var starting = false

    public init() {}

    deinit {
        if recording { _ = try? stop() }
    }

    public var isRecording: Bool { stateLock.withLock { recording } }

    public var level: Double {
        stateLock.withLock {
            Date().timeIntervalSince(lastSamplesAt) <= 0.5 ? lastLevel : 0
        }
    }

    public static func inputDevices() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
            "Read input device list size"
        )
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids),
            "List input devices"
        )

        return try ids.compactMap { id in
            let channels = try inputChannelCount(id)
            guard channels > 0 else { return nil }
            var rate = 0.0
            var rateSize = UInt32(MemoryLayout<Double>.size)
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try check(AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate), "Read device sample rate")
            return AudioInputDevice(id: id, name: try deviceName(id), channels: channels, sampleRate: rate)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    public func start(
        deviceID: AudioDeviceID,
        outputURL: URL,
        onLevel: @escaping @Sendable (Double) -> Void
    ) throws {
        try stateLock.withLock {
            guard !recording, !starting else { throw MeetingSTTCoreError.processAlreadyRunning }
            starting = true
        }
        defer { stateLock.withLock { starting = false } }
        guard let selected = try Self.inputDevices().first(where: { $0.id == deviceID }) else {
            throw MeetingSTTCoreError.recording("Could not find the selected input device (ID \(deviceID)).")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var sourceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        do {
            try Self.check(
                AudioObjectGetPropertyData(deviceID, &formatAddress, 0, nil, &formatSize, &sourceFormat),
                "Read input format"
            )
        } catch {
            throw MeetingSTTCoreError.recording("Could not open the input format for \(selected.name) (\(Int(selected.sampleRate)) Hz): \(error.localizedDescription)")
        }
        guard sourceFormat.mSampleRate > 0, sourceFormat.mChannelsPerFrame > 0 else {
            throw MeetingSTTCoreError.recording("Invalid input format for \(selected.name) (\(sourceFormat.mSampleRate) Hz, \(sourceFormat.mChannelsPerFrame) ch).")
        }

        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var file: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard status == noErr, let file else {
            throw Self.audioError(status, "Create WAV", device: selected)
        }
        do {
            status = ExtAudioFileSetProperty(
                file,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &sourceFormat
            )
            guard status == noErr else { throw Self.audioError(status, "Configure mono conversion", device: selected) }
            status = ExtAudioFileWriteAsync(file, 0, nil)
            guard status == noErr else { throw Self.audioError(status, "Prepare asynchronous WAV writer", device: selected) }

            self.deviceID = deviceID
            self.outputURL = outputURL
            self.audioFile = file
            self.sampleRate = sourceFormat.mSampleRate
            self.inputFormat = sourceFormat
            self.framesWritten = 0
            self.firstHostTime = nil
            self.sumSquares = 0
            self.sampleCount = 0
            self.lastSamplesAt = Date.distantPast
            self.lastLevel = 0

            let context = Unmanaged.passUnretained(self).toOpaque()
            status = AudioDeviceCreateIOProcID(deviceID, deviceRecorderIOProc, context, &ioProcID)
            guard status == noErr, ioProcID != nil else {
                throw Self.audioError(status, "Create IOProc", device: selected)
            }
            status = AudioDeviceStart(deviceID, ioProcID)
            guard status == noErr else { throw Self.audioError(status, "Recording started", device: selected) }
            stateLock.withLock { recording = true }

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let value = self.consumeLevel()
                onLevel(value)
            }
            levelTimer = timer
            timer.resume()
        } catch {
            if let ioProcID { AudioDeviceDestroyIOProcID(deviceID, ioProcID) }
            self.ioProcID = nil
            ExtAudioFileDispose(file)
            self.audioFile = nil
            throw error
        }
    }

    public func stop() throws -> RecordingStats {
        guard stateLock.withLock({ recording }) else { throw MeetingSTTCoreError.noProcessRunning }
        levelTimer?.cancel()
        levelTimer = nil

        var failure: Error?
        if let ioProcID {
            let stopStatus = AudioDeviceStop(deviceID, ioProcID)
            if stopStatus != noErr { failure = Self.audioError(stopStatus, "Stop recording") }
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            if destroyStatus != noErr, failure == nil { failure = Self.audioError(destroyStatus, "Clean up IOProc") }
        }
        ioProcID = nil
        if let audioFile {
            let disposeStatus = ExtAudioFileDispose(audioFile)
            if disposeStatus != noErr, failure == nil { failure = Self.audioError(disposeStatus, "WAV finalize") }
        }
        audioFile = nil
        stateLock.withLock { recording = false }
        if let failure { throw failure }

        guard let outputURL else { throw MeetingSTTCoreError.recording("No recording output path is available.") }
        let bytes = try Self.validateWAV(outputURL)
        let duration = sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
        return RecordingStats(duration: duration, bytes: bytes, startedHostTime: firstHostTime)
    }

    fileprivate func write(_ inputData: UnsafePointer<AudioBufferList>, timestamp: AudioTimeStamp) -> OSStatus {
        guard let audioFile else { return kAudio_ParamError }
        let bytesPerFrame = inputFormat.mBytesPerFrame
        guard bytesPerFrame > 0 else { return kAudio_ParamError }
        let frames = inputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
        if frames > 0, firstHostTime == nil, timestamp.mFlags.contains(.hostTimeValid) {
            firstHostTime = AVAudioTime.seconds(forHostTime: timestamp.mHostTime)
        }
        accumulateRMS(inputData)
        let status = ExtAudioFileWriteAsync(audioFile, frames, inputData)
        if status == noErr { framesWritten &+= UInt64(frames) }
        return status
    }

    private func accumulateRMS(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var sum = 0.0
        var count: UInt64 = 0
        let flags = inputFormat.mFormatFlags
        let isFloat = inputFormat.mFormatID == kAudioFormatLinearPCM && flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = inputFormat.mFormatID == kAudioFormatLinearPCM && flags & kAudioFormatFlagIsSignedInteger != 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            if isFloat && inputFormat.mBitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<n {
                    let value = Double(samples[index])
                    sum += value * value
                }
                count &+= UInt64(n)
            } else if isSignedInteger && inputFormat.mBitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                for index in 0..<n {
                    let value = Double(samples[index]) / Double(Int16.max)
                    sum += value * value
                }
                count &+= UInt64(n)
            }
        }
        guard count > 0 else { return }
        stateLock.withLock {
            sumSquares += sum
            sampleCount &+= count
            lastSamplesAt = Date()
        }
    }

    private func consumeLevel() -> Double {
        stateLock.withLock {
            guard sampleCount > 0 else {
                if Date().timeIntervalSince(lastSamplesAt) > 0.5 { lastLevel = 0 }
                return lastLevel
            }
            lastLevel = sqrt(sumSquares / Double(sampleCount))
            sumSquares = 0
            sampleCount = 0
            return lastLevel
        }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Read input stream configuration size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw), "Read input stream configuration")
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func deviceName(_ id: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Read input device name")
        guard let value else { return "Audio Device \(id)" }
        return value.takeRetainedValue() as String
    }

    private static func validateWAV(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 44 else {
            throw MeetingSTTCoreError.recording("The finalized WAV file is missing or empty: \(url.path)")
        }
        var audioFile: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard status == noErr, let audioFile else {
            throw audioError(status, "Open finalized WAV")
        }
        AudioFileClose(audioFile)
        return bytes
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw audioError(status, operation) }
    }

    private static func audioError(_ status: OSStatus, _ operation: String, device: AudioInputDevice? = nil) -> MeetingSTTCoreError {
        let code = fourCharacterCode(status)
        let selected = device.map { " (\($0.name), \(Int($0.sampleRate)) Hz)" } ?? ""
        let permission = status == kAudioHardwareNotRunningError || status == kAudioDevicePermissionsError
            ? " Allow this app in System Settings > Privacy & Security > Microphone."
            : ""
        return .recording("\(operation) failed\(selected): OSStatus \(status) [\(code)].\(permission)")
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(status) }
        return String(bytes: bytes, encoding: .ascii) ?? String(status)
    }
}

private let deviceRecorderIOProc: AudioDeviceIOProc = {
    _, _, inputData, inputTime, _, _, context in
    guard let context else { return noErr }
    let recorder = Unmanaged<DeviceRecorder>.fromOpaque(context).takeUnretainedValue()
    return recorder.write(inputData, timestamp: inputTime.pointee)
}
