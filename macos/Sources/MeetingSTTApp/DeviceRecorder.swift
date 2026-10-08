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

/// 파일이 붙는 가상 입력. 실제 장치는 여기에 붙였다 떼고, 아무 장치도 소리를 주지 않는 동안은
/// 무음을 써서 WAV 하나의 시간축이 host time과 어긋나지 않게 한다.
final class VirtualInput {
    /// 비동기 writer는 한꺼번에 약 144KB 넘게 받으면 이후 녹음을 통째로 잃는다(실측).
    /// 무음과 변환 출력은 한 번에 이만큼만 넣는다.
    private static let chunkBytes: UInt32 = 32_768

    private let lock = NSLock()
    private var file: ExtAudioFileRef?
    /// ExtAudioFile은 쓰기 시작 후 client format을 바꿀 수 없어(-66565) 처음 장치의 포맷으로 고정한다.
    private let clientFormat: AudioStreamBasicDescription
    private var sourceFormat: AudioStreamBasicDescription
    private var converter: AudioConverterRef?
    private let silence: UnsafeMutableRawPointer
    private let converted: UnsafeMutableRawPointer
    private var delivering = false
    private var framesWritten: UInt64 = 0
    private var firstHostTime: TimeInterval?
    private var origin = 0.0
    private var pausedTotal = 0.0
    private var pausedSince: TimeInterval?

    init(url: URL, format: AudioStreamBasicDescription, device: AudioInputDevice? = nil) throws {
        clientFormat = format
        sourceFormat = format
        silence = .allocate(byteCount: Int(Self.chunkBytes), alignment: 16)
        silence.initializeMemory(as: UInt8.self, repeating: 0, count: Int(Self.chunkBytes))
        converted = .allocate(byteCount: Int(Self.chunkBytes), alignment: 16)

        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var client = format
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard status == noErr, let file else {
            throw DeviceRecorder.audioError(status, "WAV 생성", device: device)
        }
        status = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &client
        )
        guard status == noErr else { throw DeviceRecorder.audioError(status, "모노 변환 포맷 설정", device: device) }
        status = ExtAudioFileWriteAsync(file, 0, nil)
        guard status == noErr else { throw DeviceRecorder.audioError(status, "WAV 비동기 writer 준비", device: device) }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        if let file { ExtAudioFileDispose(file) }
        silence.deallocate()
        converted.deallocate()
    }

    /// 새 장치의 포맷을 받는다. 처음 포맷과 다르면 변환기를 거쳐 같은 파일에 쓴다.
    func attach(format: AudioStreamBasicDescription) throws {
        var next: AudioConverterRef?
        if !Self.same(format, clientFormat) {
            guard Self.isSingleBuffer(format), Self.isSingleBuffer(clientFormat) else {
                throw MeetingSTTCoreError.recording("녹음 중 전환을 지원하지 않는 입력 포맷입니다.")
            }
            var source = format
            var client = clientFormat
            let status = AudioConverterNew(&source, &client, &next)
            guard status == noErr, next != nil else { throw DeviceRecorder.audioError(status, "입력 포맷 변환기 생성") }
        }
        lock.withLock {
            if let converter { AudioConverterDispose(converter) }
            converter = next
            sourceFormat = format
            delivering = false
        }
    }

    func detach() {
        lock.withLock { delivering = false }
    }

    /// IOProc에서 부른다. `hostTime`은 버퍼 첫 샘플의 host time(초).
    func write(_ list: UnsafePointer<AudioBufferList>, hostTime: TimeInterval?) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return kAudio_ParamError }
        if pausedSince != nil { return noErr }
        guard sourceFormat.mBytesPerFrame > 0 else { return kAudio_ParamError }
        let frames = list.pointee.mBuffers.mDataByteSize / sourceFormat.mBytesPerFrame
        guard frames > 0 else { return noErr }
        if let hostTime {
            if firstHostTime == nil {
                firstHostTime = hostTime
                origin = activeTime(hostTime)
            }
            // 막 붙은 장치는 빈 구간을 무음으로 따라잡은 뒤부터 쓴다. 따라잡는 동안의 버퍼는 버린다.
            if !delivering, !fillSilence(until: hostTime) { return noErr }
        }
        delivering = true

        guard let converter else {
            let status = ExtAudioFileWriteAsync(file, frames, list)
            if status == noErr { framesWritten &+= UInt64(frames) }
            return status
        }
        var pending = PendingInput(buffer: list.pointee.mBuffers, frames: frames)
        let capacity = Self.chunkBytes / clientFormat.mBytesPerFrame
        while true {
            var produced = capacity
            var output = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: clientFormat.mChannelsPerFrame,
                    mDataByteSize: capacity * clientFormat.mBytesPerFrame,
                    mData: converted
                )
            )
            let status = AudioConverterFillComplexBuffer(converter, converterInput, &pending, &produced, &output, nil)
            if produced > 0 {
                let writeStatus = ExtAudioFileWriteAsync(file, produced, &output)
                guard writeStatus == noErr else { return writeStatus }
                framesWritten &+= UInt64(produced)
            }
            if status != noErr || produced == 0 { return status == converterStarved ? noErr : status }
        }
    }

    /// 아무 장치도 소리를 주지 않는 동안 주기적으로 불러 무음을 잇는다.
    func tick(hostTime: TimeInterval) {
        lock.withLock {
            if !delivering { _ = fillSilence(until: hostTime) }
        }
    }

    /// 일시 정지 중에는 시간축이 흐르지 않아 무음도 쌓이지 않는다.
    func setPaused(_ paused: Bool, at hostTime: TimeInterval) {
        lock.withLock {
            if paused {
                if pausedSince == nil { pausedSince = hostTime }
            } else if let since = pausedSince {
                pausedTotal += max(0, hostTime - since)
                pausedSince = nil
            }
        }
    }

    func finish() throws -> (duration: TimeInterval, startedHostTime: TimeInterval?) {
        try lock.withLock {
            if let converter { AudioConverterDispose(converter) }
            converter = nil
            guard let file else { throw MeetingSTTCoreError.noProcessRunning }
            self.file = nil
            let status = ExtAudioFileDispose(file)
            guard status == noErr else { throw DeviceRecorder.audioError(status, "WAV finalize") }
            return (Double(framesWritten) / clientFormat.mSampleRate, firstHostTime)
        }
    }

    /// 파일이 `hostTime`까지 와 있도록 무음을 쓴다. 한 번에 넣을 수 있는 양으로 다 못 채우면 false.
    private func fillSilence(until hostTime: TimeInterval) -> Bool {
        guard let file, firstHostTime != nil, Self.isSingleBuffer(clientFormat), clientFormat.mBytesPerFrame > 0 else { return true }
        let missing = (activeTime(hostTime) - origin) * clientFormat.mSampleRate - Double(framesWritten)
        guard missing >= 1 else { return true }
        let capacity = Self.chunkBytes / clientFormat.mBytesPerFrame
        let frames = UInt32(min(missing, Double(capacity)))
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: clientFormat.mChannelsPerFrame,
                mDataByteSize: frames * clientFormat.mBytesPerFrame,
                mData: silence
            )
        )
        guard ExtAudioFileWriteAsync(file, frames, &list) == noErr else { return true }
        framesWritten &+= UInt64(frames)
        return missing <= Double(capacity)
    }

    /// 일시 정지 구간을 뺀 host time.
    private func activeTime(_ hostTime: TimeInterval) -> TimeInterval {
        hostTime - pausedTotal - (pausedSince.map { max(0, hostTime - $0) } ?? 0)
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    // ponytail: 버퍼 하나짜리(모노 또는 인터리브) 포맷끼리만 변환·무음을 지원한다. HAL 입력 스트림은 사실상
    // 전부 이 형태이고 DeviceRecorder.write의 프레임 계산도 같은 전제다. 아니면 스트림별 버퍼를 다뤄야 한다.
    private static func isSingleBuffer(_ format: AudioStreamBasicDescription) -> Bool {
        format.mChannelsPerFrame == 1 || format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }
}

private struct PendingInput {
    var buffer: AudioBuffer
    var frames: UInt32
}

/// "이번 콜백의 입력은 다 줬다"는 표시. noErr로 0개를 돌려주면 변환기가 스트림 끝으로 받아들인다.
private let converterStarved: OSStatus = 1

private let converterInput: AudioConverterComplexInputDataProc = { _, packetCount, data, _, context in
    guard let pending = context?.assumingMemoryBound(to: PendingInput.self), pending.pointee.frames > 0 else {
        packetCount.pointee = 0
        return converterStarved
    }
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers = pending.pointee.buffer
    packetCount.pointee = pending.pointee.frames
    pending.pointee.frames = 0
    return noErr
}

public final class DeviceRecorder {
    private let stateLock = NSLock()
    /// 장치를 붙이고 떼는 일과 stop을 한 줄로 세운다.
    private let control = DispatchQueue(label: "MeetingSTT.DeviceRecorder.control")
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var input: VirtualInput?
    private var outputURL: URL?
    private var selectedUID: String?
    private var reportedDeviceID: AudioDeviceID?
    private var onDeviceChange: (@Sendable (String?, Bool) -> Void)?
    private var sumSquares = 0.0
    private var sampleCount: UInt64 = 0
    private var lastSamplesAt = Date.distantPast
    private var lastLevel = 0.0
    private var levelTimer: DispatchSourceTimer?
    private var silenceTimer: DispatchSourceTimer?
    private var inputFormat = AudioStreamBasicDescription()
    private var recording = false
    private var starting = false
    private var paused = false

    public init() {}

    deinit {
        // stop()은 control 큐를 기다리므로 여기서는 직접 정리한다. WAV는 VirtualInput이 닫는다.
        guard recording else { return }
        levelTimer?.cancel()
        silenceTimer?.cancel()
        watchDevices(false)
        detach()
    }

    public var isRecording: Bool { stateLock.withLock { recording } }

    public var level: Double {
        stateLock.withLock {
            Date().timeIntervalSince(lastSamplesAt) <= 0.5 ? lastLevel : 0
        }
    }

    public static func inputDevices() throws -> [AudioInputDevice] {
        try deviceIDs().compactMap { try device($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
            "입력 장치 목록 크기 조회"
        )
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids),
            "입력 장치 목록 조회"
        )
        return ids
    }

    /// 입력 채널이 없는 장치는 nil.
    private static func device(_ id: AudioDeviceID) throws -> AudioInputDevice? {
        let channels = try inputChannelCount(id)
        guard channels > 0 else { return nil }
        var rate = 0.0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate), "장치 샘플레이트 조회")
        return AudioInputDevice(id: id, name: try deviceName(id), channels: channels, sampleRate: rate)
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

    /// `onDeviceChange`: 녹음 중 실제 장치가 바뀌면 새 장치 이름(붙일 장치가 없으면 nil)과
    /// 그것이 처음 고른 장치인지를 알린다.
    public func start(
        deviceID: AudioDeviceID,
        outputURL: URL,
        onLevel: @escaping @Sendable (Double) -> Void,
        onDeviceChange: @escaping @Sendable (String?, Bool) -> Void = { _, _ in }
    ) throws {
        try stateLock.withLock {
            guard !recording, !starting else { throw MeetingSTTCoreError.processAlreadyRunning }
            starting = true
            paused = false
        }
        defer { stateLock.withLock { starting = false } }
        guard let selected = try Self.inputDevices().first(where: { $0.id == deviceID }) else {
            throw MeetingSTTCoreError.recording("선택한 입력 장치를 찾을 수 없습니다 (ID \(deviceID)).")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let input = try VirtualInput(url: outputURL, format: try Self.streamFormat(selected), device: selected)
        stateLock.withLock {
            self.input = input
            sumSquares = 0
            sampleCount = 0
            lastSamplesAt = Date.distantPast
            lastLevel = 0
        }
        self.outputURL = outputURL
        self.selectedUID = Self.deviceUID(deviceID)
        self.reportedDeviceID = deviceID
        self.onDeviceChange = onDeviceChange
        do {
            try control.sync { try attach(selected) }
        } catch {
            stateLock.withLock { self.input = nil }
            throw error
        }
        stateLock.withLock { recording = true }
        watchDevices(true)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let value = self.consumeLevel()
            onLevel(value)
        }
        levelTimer = timer
        timer.resume()

        let silence = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        silence.schedule(deadline: .now() + 0.05, repeating: 0.05)
        silence.setEventHandler {
            // 장치는 버퍼에 지금보다 조금 이른 시각을 찍어 보내므로 그만큼은 첫 버퍼가 채우게 남겨 둔다.
            input.tick(hostTime: AVAudioTime.seconds(forHostTime: mach_absolute_time()) - 0.05)
        }
        silenceTimer = silence
        silence.resume()
    }

    public func stop() throws -> RecordingStats {
        guard stateLock.withLock({ recording }) else { throw MeetingSTTCoreError.noProcessRunning }
        levelTimer?.cancel()
        levelTimer = nil
        silenceTimer?.cancel()
        silenceTimer = nil
        watchDevices(false)
        control.sync {
            stateLock.withLock { recording = false }
            detach()
        }
        let input = stateLock.withLock {
            defer { self.input = nil }
            return self.input
        }
        guard let input, let outputURL else { throw MeetingSTTCoreError.recording("녹음 출력 경로가 없습니다.") }
        let (duration, startedHostTime) = try input.finish()
        let bytes = try Self.validateWAV(outputURL)
        return RecordingStats(duration: duration, bytes: bytes, startedHostTime: startedHostTime)
    }

    /// 일시 정지 중에는 장치와 파일을 유지한 채 들어오는 프레임을 버린다.
    public func setPaused(_ paused: Bool) {
        let input = stateLock.withLock {
            self.paused = paused
            return self.input
        }
        input?.setPaused(paused, at: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
    }

    /// 장치를 가상 입력에 붙인다. control 큐에서만 부른다.
    private func attach(_ device: AudioInputDevice) throws {
        guard let input = stateLock.withLock({ self.input }) else { throw MeetingSTTCoreError.noProcessRunning }
        let format = try Self.streamFormat(device)
        try input.attach(format: format)
        stateLock.withLock {
            deviceID = device.id
            inputFormat = format
        }
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(device.id, deviceRecorderIOProc, Unmanaged.passUnretained(self).toOpaque(), &procID)
        var operation = "IOProc 생성"
        if status == noErr, let procID {
            operation = "녹음 시작"
            status = AudioDeviceStart(device.id, procID)
            if status != noErr { AudioDeviceDestroyIOProcID(device.id, procID) }
        }
        guard status == noErr, let procID else {
            stateLock.withLock { deviceID = AudioDeviceID(kAudioObjectUnknown) }
            throw Self.audioError(status, operation, device: device)
        }
        ioProcID = procID
    }

    private func detach() {
        if let ioProcID {
            // 장치가 이미 사라졌으면 둘 다 실패한다. 멈출 것이 없다는 뜻이므로 녹음 실패로 보지 않는다.
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
        let input = stateLock.withLock {
            deviceID = AudioDeviceID(kAudioObjectUnknown)
            return self.input
        }
        input?.detach()
    }

    private func watchDevices(_ watch: Bool) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let system = AudioObjectID(kAudioObjectSystemObject)
            if watch {
                AudioObjectAddPropertyListener(system, &address, deviceRecorderDevicesChanged, context)
            } else {
                AudioObjectRemovePropertyListener(system, &address, deviceRecorderDevicesChanged, context)
            }
        }
    }

    fileprivate func devicesChanged() {
        control.async { [weak self] in self?.reconcile() }
    }

    /// 처음 고른 장치가 있으면 그 장치, 없으면 쓰던 장치, 그것도 없으면 기본 입력 장치를 붙인다.
    private func reconcile() {
        // 목록을 못 읽었을 때 멀쩡한 장치를 떼지 않는다.
        guard stateLock.withLock({ recording }), let ids = try? Self.deviceIDs() else { return }
        let current = ioProcID != nil && ids.contains(deviceID) ? deviceID : nil
        let selected = selectedUID.flatMap { uid in ids.first { Self.deviceUID($0) == uid } }
        let candidates = [selected, current, Self.defaultInputDeviceID()].compactMap { $0 }
        guard candidates.first != current else { return }
        detach()
        let attached = candidates.lazy
            .compactMap { try? Self.device($0) }
            .first { (try? self.attach($0)) != nil }
        guard attached?.id != reportedDeviceID else { return }
        reportedDeviceID = attached?.id
        onDeviceChange?(attached?.name, attached != nil && attached?.id == selected)
    }

    fileprivate func write(_ inputData: UnsafePointer<AudioBufferList>, timestamp: AudioTimeStamp, from device: AudioDeviceID) -> OSStatus {
        // 떼어 낸 장치가 늦게 보낸 콜백과 일시 정지 중의 프레임은 버린다.
        let live = stateLock.withLock { device == deviceID && !paused ? input.map { ($0, inputFormat) } : nil }
        guard let (input, format) = live else { return noErr }
        accumulateRMS(inputData, format: format)
        let hostTime = timestamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: timestamp.mHostTime) : nil
        return input.write(inputData, hostTime: hostTime)
    }

    private func accumulateRMS(_ list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var sum = 0.0
        var count: UInt64 = 0
        let flags = format.mFormatFlags
        let isFloat = format.mFormatID == kAudioFormatLinearPCM && flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatID == kAudioFormatLinearPCM && flags & kAudioFormatFlagIsSignedInteger != 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            if isFloat && format.mBitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<n {
                    let value = Double(samples[index])
                    sum += value * value
                }
                count &+= UInt64(n)
            } else if isSignedInteger && format.mBitsPerChannel == 16 {
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
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "입력 stream configuration 크기 조회")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw), "입력 stream configuration 조회")
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
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "입력 장치 이름 조회")
        guard let value else { return "Audio Device \(id)" }
        return value.takeRetainedValue() as String
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func streamFormat(_ device: AudioInputDevice) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        do {
            try check(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &format), "입력 포맷 조회")
        } catch {
            throw MeetingSTTCoreError.recording("\(device.name) (\(Int(device.sampleRate)) Hz) 입력 포맷을 열 수 없습니다: \(error.localizedDescription)")
        }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw MeetingSTTCoreError.recording("\(device.name)의 입력 포맷이 올바르지 않습니다 (\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch).")
        }
        return format
    }

    private static func validateWAV(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 44 else {
            throw MeetingSTTCoreError.recording("WAV finalize 후 파일이 없거나 비어 있습니다: \(url.path)")
        }
        var audioFile: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard status == noErr, let audioFile else {
            throw audioError(status, "finalize된 WAV 열기")
        }
        AudioFileClose(audioFile)
        return bytes
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw audioError(status, operation) }
    }

    fileprivate static func audioError(_ status: OSStatus, _ operation: String, device: AudioInputDevice? = nil) -> MeetingSTTCoreError {
        let code = fourCharacterCode(status)
        let selected = device.map { " (\($0.name), \(Int($0.sampleRate)) Hz)" } ?? ""
        let permission = status == kAudioHardwareNotRunningError || status == kAudioDevicePermissionsError
            ? " 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 이 앱을 허용하세요."
            : ""
        return .recording("\(operation) 실패\(selected): OSStatus \(status) [\(code)].\(permission)")
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(status) }
        return String(bytes: bytes, encoding: .ascii) ?? String(status)
    }
}

private let deviceRecorderIOProc: AudioDeviceIOProc = {
    device, _, inputData, inputTime, _, _, context in
    guard let context else { return noErr }
    let recorder = Unmanaged<DeviceRecorder>.fromOpaque(context).takeUnretainedValue()
    return recorder.write(inputData, timestamp: inputTime.pointee, from: device)
}

private let deviceRecorderDevicesChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
    guard let context else { return noErr }
    Unmanaged<DeviceRecorder>.fromOpaque(context).takeUnretainedValue().devicesChanged()
    return noErr
}
