// apptap — macOS 앱별 / 시스템 전체 오디오 캡처 헬퍼 (Core Audio Process Tap, macOS 14.2+)
//
// 사용:
//   apptap list                          # 오디오 프로세스 목록(JSON)
//   apptap record --pid N --out f.wav    # PID 오디오 녹음 (SIGINT/SIGTERM에 finalize)
//   apptap record-system --out f.wav     # 시스템 전체 출력 믹스 녹음 (SIGINT/SIGTERM에 finalize)
//
// record / record-system 둘 다 실시간 레벨(RMS)을 stdout에 약 200ms마다 한 줄로 출력:
//   LEVEL <float>\n        # 예: "LEVEL 0.012300"  (무음이면 "LEVEL 0.0")
// SIGUSR1 = 일시 정지, SIGUSR2 = 재개 (준비되면 stdout에 "PAUSABLE" 한 줄).
// stderr에는 기존 시작 로그를 유지한다.
//
// 빌드:
//   swiftc -O native/apptap.swift -o native/apptap \
//     -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AppKit

// MARK: - Core Audio 프로퍼티 헬퍼

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func scalar<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var a = addr(selector)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
    return st == noErr ? v : nil
}

func cfString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = addr(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var cf: Unmanaged<CFString>?
    let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf)
    guard st == noErr, let cf = cf else { return nil }
    return cf.takeRetainedValue() as String
}

func processObjects() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var arr = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &arr) == noErr else { return [] }
    return arr
}

func processPID(_ obj: AudioObjectID) -> pid_t? {
    scalar(obj, kAudioProcessPropertyPID, pid_t(-1)).flatMap { $0 >= 0 ? $0 : nil }
}

func processBundleID(_ obj: AudioObjectID) -> String? {
    cfString(obj, kAudioProcessPropertyBundleID)
}

func processObject(forPID pid: pid_t) -> AudioObjectID? {
    for obj in processObjects() where processPID(obj) == pid { return obj }
    return nil
}

// MARK: - list

func runList() {
    var items: [[String: Any]] = []
    let running = NSWorkspace.shared.runningApplications
    for obj in processObjects() {
        guard let pid = processPID(obj) else { continue }
        let bundle = processBundleID(obj) ?? ""
        let app = running.first { $0.processIdentifier == pid }
        let name = app?.localizedName ?? bundle.split(separator: ".").last.map(String.init) ?? "pid \(pid)"
        items.append(["pid": Int(pid), "name": name, "bundleID": bundle])
    }
    // 이름 기준 정렬, 이름 없는 시스템 프로세스는 뒤로
    items.sort { ("\($0["name"]!)").localizedCaseInsensitiveCompare("\($1["name"]!)") == .orderedAscending }
    let data = try! JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

// MARK: - record

final class Recorder {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var extFile: ExtAudioFileRef?
    var asbd = AudioStreamBasicDescription()

    // 실시간 레벨(RMS) 누적 — IOProc(실시간 스레드)와 메인 타이머가 공유.
    // os_unfair_lock으로 짧게 보호한다(IOProc에서 락 보유 최소화).
    var levelLock = os_unfair_lock_s()
    var sumSquares: Double = 0
    var sampleCount: UInt64 = 0
    var firstHostTime: Double?
    var emittedStart = false
    var paused = false

    // 일시 정지 중에는 탭·파일을 유지한 채 IOProc가 프레임을 버린다.
    func setPaused(_ value: Bool) {
        os_unfair_lock_lock(&levelLock)
        paused = value
        os_unfair_lock_unlock(&levelLock)
    }

    func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(("[apptap] " + msg + "\n").data(using: .utf8)!)
        cleanup()
        exit(1)
    }

    // 앱(pid) 탭 녹음 시작.
    func start(pid: pid_t, outPath: String) {
        guard let procObj = processObject(forPID: pid) else {
            fail("PID \(pid)의 오디오 프로세스를 찾을 수 없습니다. 그 앱이 소리를 내고 있나요?")
        }
        // Process Tap 생성 (들으면서 캡처: .unmuted)
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [procObj])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted
        tapDesc.name = "meeting_stt tap \(pid)"
        tapDesc.isPrivate = true
        startWithTap(tapDesc, outPath: outPath, label: "pid \(pid)")
    }

    // 시스템 전체 출력 믹스 탭 녹음 시작 (pid 불필요).
    func startGlobal(outPath: String) {
        // 전역 탭: 모든 프로세스 출력 믹스를 스테레오로 캡처(제외 목록 비움).
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted
        tapDesc.name = "meeting_stt system tap"
        tapDesc.isPrivate = true
        startWithTap(tapDesc, outPath: outPath, label: "system")
    }

    // 탭 생성 이후 공통 경로: 포맷 읽기 → aggregate → wav → IOProc → start.
    private func startWithTap(_ tapDesc: CATapDescription, outPath: String, label: String) {
        // 1) Process Tap 생성
        var st = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        if st != noErr || tapID == kAudioObjectUnknown {
            fail("Process Tap 생성 실패(OSStatus \(st)). 시스템 설정 > 개인정보 보호 > 오디오 녹음에서 터미널 권한을 허용하세요.")
        }

        // 2) 탭 포맷 / UID
        guard let fmt = scalar(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()) else {
            fail("탭 포맷을 읽지 못했습니다.")
        }
        asbd = fmt
        guard let tapUID = cfString(tapID, kAudioTapPropertyUID) else { fail("탭 UID를 읽지 못했습니다.") }

        // 3) Aggregate device 생성 (탭 포함)
        let aggUID = "meeting_stt-agg-\(getpid())"
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceNameKey as String: "meeting_stt aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        if st != noErr || aggID == kAudioObjectUnknown {
            fail("집합 장치 생성 실패(OSStatus \(st)).")
        }

        // 4) 출력 wav (file: Int16 PCM, client: 탭 Float32)
        var fileASBD = AudioStreamBasicDescription(
            mSampleRate: asbd.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * asbd.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * asbd.mChannelsPerFrame,
            mChannelsPerFrame: asbd.mChannelsPerFrame,
            mBitsPerChannel: 16,
            mReserved: 0)
        let url = URL(fileURLWithPath: outPath) as CFURL
        st = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &extFile)
        if st != noErr || extFile == nil { fail("wav 생성 실패(OSStatus \(st)): \(outPath)") }
        var clientASBD = asbd
        st = ExtAudioFileSetProperty(extFile!, kExtAudioFileProperty_ClientDataFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
        if st != noErr { fail("client format 설정 실패(OSStatus \(st)).") }

        // 5) IOProc 설치 — self를 context로 전달
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        st = AudioDeviceCreateIOProcID(aggID, ioProc, ctx, &procID)
        if st != noErr || procID == nil { fail("IOProc 생성 실패(OSStatus \(st)).") }
        st = AudioDeviceStart(aggID, procID)
        if st != noErr { fail("녹음 시작 실패(OSStatus \(st)).") }

        FileHandle.standardError.write("[apptap] 녹음 시작 (\(label), \(Int(asbd.mSampleRate))Hz, \(asbd.mChannelsPerFrame)ch) → \(outPath)\n".data(using: .utf8)!)
    }

    // 누적된 RMS를 한 줄로 stdout에 쓰고 누적값을 리셋한다(메인 타이머에서 호출).
    func emitLevel() {
        os_unfair_lock_lock(&levelLock)
        let s = sumSquares
        let c = sampleCount
        let start = firstHostTime
        sumSquares = 0
        sampleCount = 0
        os_unfair_lock_unlock(&levelLock)
        if !emittedStart, let start {
            FileHandle.standardOutput.write("START_HOST \(start)\n".data(using: .utf8)!)
            emittedStart = true
        }
        let rms = c > 0 ? (s / Double(c)).squareRoot() : 0.0
        let line = c > 0 ? String(format: "LEVEL %.6f\n", rms) : "LEVEL 0.0\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }

    func cleanup() {
        if let p = procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            procID = nil
        }
        emitLevel()
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        if let f = extFile { ExtAudioFileDispose(f); extFile = nil }
    }
}

// IOProc (전역 C 함수) — context에서 Recorder를 꺼내 wav 기록 + RMS 누적.
// 실시간 스레드이므로 ExtAudioFileWriteAsync(실시간 안전)와 짧은 락만 사용한다.
let ioProc: AudioDeviceIOProc = { (_, _, inInputData, inputTime, _, _, context) -> OSStatus in
    guard let context = context else { return noErr }
    let rec = Unmanaged<Recorder>.fromOpaque(context).takeUnretainedValue()
    guard let ext = rec.extFile else { return noErr }
    let bytesPerFrame = max(rec.asbd.mBytesPerFrame, 1)
    let buffers = inInputData.pointee
    let firstSize = buffers.mBuffers.mDataByteSize
    let frames = firstSize / bytesPerFrame
    if frames == 0 { return noErr }

    os_unfair_lock_lock(&rec.levelLock)
    let paused = rec.paused
    if !paused, rec.firstHostTime == nil, inputTime.pointee.mFlags.contains(.hostTimeValid) {
        rec.firstHostTime = AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime)
    }
    os_unfair_lock_unlock(&rec.levelLock)
    if paused { return noErr }

    // RMS 누적 (Float32, interleaved/non-interleaved 모두 모든 buffer 순회).
    if rec.asbd.mFormatID == kAudioFormatLinearPCM,
       (rec.asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
       rec.asbd.mBitsPerChannel == 32 {
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData)
        )
        var localSum: Double = 0
        var localCount: UInt64 = 0
        for buffer in bufferList {
            guard let raw = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let samples = raw.assumingMemoryBound(to: Float32.self)
            for index in 0..<count {
                let value = Double(samples[index])
                localSum += value * value
            }
            localCount += UInt64(count)
        }
        if localCount > 0 {
            os_unfair_lock_lock(&rec.levelLock)
            rec.sumSquares += localSum
            rec.sampleCount += localCount
            os_unfair_lock_unlock(&rec.levelLock)
        }
    }

    return ExtAudioFileWriteAsync(ext, frames, inInputData)
}

// MARK: - 인자 파싱 + 시그널

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}

// record / record-system 공통: 시그널 처리 + 200ms LEVEL 타이머 런루프.
func runRecordLoop(_ rec: Recorder) {
    // SIGINT/SIGTERM에 정리 후 종료
    var keepRunning = true
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigSrc.setEventHandler { rec.cleanup(); keepRunning = false; exit(0) }
    sigSrc.resume()
    let sigSrc2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigSrc2.setEventHandler { rec.cleanup(); keepRunning = false; exit(0) }
    sigSrc2.resume()
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    // SIGUSR1/SIGUSR2 = 일시 정지/재개. 핸들러 설치 뒤에 PAUSABLE을 알려,
    // 부모가 이 신호를 모르는 옛 바이너리에 보내 녹음을 죽이는 일을 막는다.
    let pauseSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    pauseSrc.setEventHandler { rec.setPaused(true) }
    pauseSrc.resume()
    let resumeSrc = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    resumeSrc.setEventHandler { rec.setPaused(false) }
    resumeSrc.resume()
    signal(SIGUSR1, SIG_IGN)
    signal(SIGUSR2, SIG_IGN)
    FileHandle.standardOutput.write("PAUSABLE\n".data(using: .utf8)!)

    // 약 200ms마다 stdout에 LEVEL 한 줄(하트비트 신호원).
    let levelTimer = DispatchSource.makeTimerSource(queue: .main)
    levelTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
    levelTimer.setEventHandler { rec.emitLevel() }
    levelTimer.resume()

    while keepRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

switch command {
case "list":
    runList()
case "record":
    guard let pidStr = argValue("--pid"), let pid = pid_t(pidStr) else {
        FileHandle.standardError.write("사용: apptap record --pid N --out FILE.wav\n".data(using: .utf8)!); exit(2)
    }
    guard let out = argValue("--out") else {
        FileHandle.standardError.write("사용: apptap record --pid N --out FILE.wav\n".data(using: .utf8)!); exit(2)
    }
    let rec = Recorder()
    rec.start(pid: pid, outPath: out)
    runRecordLoop(rec)
case "record-system":
    guard let out = argValue("--out") else {
        FileHandle.standardError.write("사용: apptap record-system --out FILE.wav\n".data(using: .utf8)!); exit(2)
    }
    let rec = Recorder()
    rec.startGlobal(outPath: out)
    runRecordLoop(rec)
default:
    FileHandle.standardError.write("사용: apptap [list | record --pid N --out FILE.wav | record-system --out FILE.wav]\n".data(using: .utf8)!)
    exit(2)
}
