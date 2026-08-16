import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renameSessionID: String?
    @State private var renameDraft = ""
    @State private var deleteSessionID: String?
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            sessionSidebar
                .navigationSplitViewColumnWidth(
                    min: Layout.sidebarMinimum,
                    ideal: Layout.sidebarIdeal,
                    max: Layout.sidebarMaximum
                )
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.large) {
                    environmentBanner
                    recordingSection
                    if let session = model.selectedSession {
                        sessionSection(session)
                        transcriptionSection(session)
                        resultsSection
                    } else {
                        ContentUnavailableView(
                            "녹음을 선택하세요",
                            systemImage: "waveform",
                            description: Text("새 녹음을 시작하거나 왼쪽 목록에서 저장된 녹음을 선택할 수 있습니다.")
                        )
                    }
                    logSection
                }
                .padding(Layout.xLarge)
                .frame(maxWidth: Layout.contentMaximum, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle(model.selectedSession.map(model.sessionTitle) ?? "회의 전사")
        }
        .task { await model.start() }
        .alert("이름 변경", isPresented: renamePresented) {
            TextField("세션 이름", text: $renameDraft)
                .focused($renameFieldFocused)
            Button("취소", role: .cancel) { renameSessionID = nil }
            Button("저장") {
                guard let id = renameSessionID else { return }
                model.renameSession(id: id, name: renameDraft)
                renameSessionID = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("비워 두면 날짜 기반 기본 이름을 사용합니다.")
        }
        .alert("세션을 삭제할까요?", isPresented: deletePresented) {
            Button("취소", role: .cancel) { deleteSessionID = nil }
            Button("삭제", role: .destructive) {
                guard let id = deleteSessionID else { return }
                model.deleteSession(id: id)
                deleteSessionID = nil
            }
        } message: {
            Text("녹음과 이 세션에서 만든 전사·회의록 파일이 함께 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "저장된 녹음이 없습니다",
                    systemImage: "waveform.badge.plus",
                    description: Text("오른쪽에서 소스를 선택하고 첫 녹음을 시작하세요.")
                )
            } else {
                List(selection: $model.selectedSessionID) {
                    ForEach(model.sessions) { session in
                        sessionRow(session)
                            .tag(Optional(session.id))
                            .contextMenu {
                                Button("이름 변경…") { beginRename(session) }
                                    .disabled(model.isBusy)
                                Button("삭제…", role: .destructive) { deleteSessionID = session.id }
                                    .disabled(model.isBusy)
                            }
                    }
                }
                .onChange(of: model.selectedSessionID) { _, _ in model.loadSelectedSession() }
            }
        }
        .navigationTitle("저장된 녹음")
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshSessions()
                } label: {
                    Label("녹음 목록 새로고침", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
            }
        }
    }

    private func sessionRow(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: Layout.xSmall) {
            Text(model.sessionTitle(session))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: Layout.small) {
                Label(
                    session.transcribed ? "전사됨" : model.sessionStatus(session),
                    systemImage: session.transcribed ? "checkmark.circle.fill" : "waveform"
                )
                .foregroundStyle(session.transcribed ? Color.green : Color.secondary)
                if let duration = session.duration {
                    Text(clockText(duration))
                }
                if session.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Layout.xSmall)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var environmentBanner: some View {
        if let error = model.errorMessage {
            GroupBox {
                HStack(alignment: .top, spacing: Layout.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("닫기") { model.dismissError() }
                }
            }
            .accessibilityLabel("오류: \(error)")
        } else if !model.rootPath.isEmpty {
            LabeledContent("프로젝트") {
                Text(model.rootPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var recordingSection: some View {
        GroupBox("녹음") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                Picker("오디오 소스", selection: $model.captureSource) {
                    ForEach(CaptureSource.allCases) { source in
                        Label(source.title, systemImage: source.systemImage).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)

                sourcePicker
                    .disabled(model.isBusy)

                HStack(spacing: Layout.small) {
                    if model.isRecordingOrStopping {
                        Button {
                            Task { await model.stopRecording() }
                        } label: {
                            Label(
                                model.isStartingRecording ? "준비 중…" : (model.isStopping ? "정지 중…" : "녹음 정지"),
                                systemImage: "stop.fill"
                            )
                        }
                        .disabled(!model.canStopRecording)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    } else {
                        Button {
                            Task { await model.startRecording() }
                        } label: {
                            Label("녹음 시작", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartRecording)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    Text(model.activityDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if model.isRecordingOrStopping {
                    Grid(alignment: .leading, horizontalSpacing: Layout.large, verticalSpacing: Layout.small) {
                        GridRow {
                            Text("경과 시간")
                            Text(clockText(model.elapsed, alwaysShowHours: true))
                                .monospacedDigit()
                        }
                        GridRow {
                            Text("파일 크기")
                            Text(ByteCountFormatter.string(fromByteCount: model.recordedBytes, countStyle: .file))
                                .monospacedDigit()
                        }
                        GridRow {
                            Text(model.captureSource == .device ? "입력 레벨" : "출력 레벨")
                            HStack(spacing: Layout.small) {
                                ProgressView(value: model.rmsLevel, total: 1)
                                    .frame(minWidth: Layout.compactControl)
                                Text(model.rmsLevel.formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .accessibilityLabel(model.captureSource == .device ? "입력 레벨" : "출력 레벨")
                            .accessibilityValue(model.rmsLevel.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .padding(Layout.xSmall)
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        switch model.captureSource {
        case .device:
            LabeledContent("입력 장치") {
                HStack(spacing: Layout.small) {
                    Picker("입력 장치", selection: $model.selectedDeviceID) {
                        if model.devices.isEmpty {
                            Text("사용 가능한 장치 없음").tag(Optional<AudioDeviceID>.none)
                        }
                        ForEach(model.devices) { device in
                            Text(model.deviceTitle(device)).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("입력 장치 새로고침", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("입력 장치 새로고침")
                }
            }
        case .app:
            LabeledContent("대상 앱") {
                HStack(spacing: Layout.small) {
                    Picker("대상 앱", selection: $model.selectedAppPID) {
                        if model.apps.isEmpty {
                            Text("캡처 가능한 앱 없음").tag(Optional<pid_t>.none)
                        }
                        ForEach(model.apps) { app in
                            Text(model.appTitle(app)).tag(Optional(app.pid))
                        }
                    }
                    .labelsHidden()
                    Button {
                        Task { await model.refreshApps() }
                    } label: {
                        Label("앱 목록 새로고침", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("앱 목록 새로고침")
                }
            }
        case .system:
            LabeledContent("대상") {
                Text("이 Mac의 전체 시스템 출력")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionSection(_ session: RecordingSession) -> some View {
        GroupBox("선택한 녹음") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                LabeledContent("세션") { Text(session.id).textSelection(.enabled) }
                LabeledContent("상태") { Text(model.sessionStatus(session)) }
                if let audioURL = session.audioURL {
                    LabeledContent("파일") {
                        Text(audioURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: Layout.small) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(model.isPlaying ? "일시 정지" : "재생", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(session.audioURL == nil)

                    Slider(
                        value: Binding(
                            get: { model.playbackPosition },
                            set: { model.seekPlayback(to: $0) }
                        ),
                        in: 0...max(model.playbackDuration, 1)
                    )
                    .accessibilityLabel("재생 위치")
                    Text(clockText(model.playbackPosition))
                        .monospacedDigit()
                    Text("/")
                        .foregroundStyle(.secondary)
                    Text(clockText(model.playbackDuration))
                        .monospacedDigit()

                    Spacer()
                    Button("이름 변경…") { beginRename(session) }
                        .disabled(model.isBusy)
                    Button("삭제…", role: .destructive) { deleteSessionID = session.id }
                        .disabled(model.isBusy)
                }
            }
            .padding(Layout.xSmall)
        }
    }

    private func transcriptionSection(_ session: RecordingSession) -> some View {
        GroupBox("전사") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                TextField("Context 키워드 (쉼표 구분)", text: $model.context)
                    .disabled(model.isBusy)
                HStack(spacing: Layout.large) {
                    Picker("화자 수", selection: $model.speakerCount) {
                        Text("자동").tag(Optional<Int>.none)
                        ForEach(1...20, id: \.self) { count in
                            Text("\(count)명").tag(Optional(count))
                        }
                    }
                    .frame(maxWidth: Layout.compactControl)
                    TextField("프로젝트", text: $model.project)
                    Toggle("화자분리", isOn: $model.diarize)
                }
                .disabled(model.isBusy)

                HStack(spacing: Layout.small) {
                    if model.isWorkerRunning {
                        Button("작업 취소", role: .cancel) {
                            Task { await model.cancelWorker() }
                        }
                        .keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            Task { await model.transcribe(sessionID: session.id) }
                        } label: {
                            Label(session.transcribed ? "다시 전사" : "전사 시작", systemImage: "text.waveform")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRunWorker || session.audioURL == nil)
                    }
                    Text(model.workerDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Layout.xSmall)
        }
    }

    private var resultsSection: some View {
        GroupBox("결과") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                HStack(spacing: Layout.small) {
                    Picker("결과 종류", selection: $model.resultKind) {
                        ForEach(ResultKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    Spacer()
                    Button("회의록 생성") {
                        Task { await model.generateNotes(promptOnly: false) }
                    }
                    .disabled(!model.canGenerateNotes)
                    Button("AI 회의록") {
                        Task { await model.generateNotes(promptOnly: false, ai: true) }
                    }
                    .disabled(!model.canGenerateNotes)
                    Button("AI 요약 프롬프트") {
                        Task { await model.generateNotes(promptOnly: true) }
                    }
                    .disabled(!model.canGenerateNotes)
                    Button {
                        model.copyCurrentResult()
                    } label: {
                        Label("현재 결과 복사", systemImage: "doc.on.doc")
                    }
                    .disabled(model.currentResultText.isEmpty)
                }

                if model.currentResultText.isEmpty {
                    ContentUnavailableView(
                        "표시할 결과가 없습니다",
                        systemImage: "doc.text",
                        description: Text(model.resultKind.emptyDescription)
                    )
                    .frame(minHeight: Layout.resultMinimumHeight)
                } else {
                    ResultTextView(text: model.currentResultText)
                    .frame(minHeight: Layout.resultMinimumHeight, maxHeight: Layout.resultMaximumHeight)
                }
            }
            .padding(Layout.xSmall)
        }
    }

    private var logSection: some View {
        DisclosureGroup("작업 로그") {
            if model.logLines.isEmpty {
                Text("아직 작업 로그가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Layout.small)
            } else {
                ScrollView {
                    Text(model.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Layout.logMaximumHeight)
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameSessionID != nil },
            set: { if !$0 { renameSessionID = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteSessionID != nil },
            set: { if !$0 { deleteSessionID = nil } }
        )
    }

    private func beginRename(_ session: RecordingSession) {
        renameDraft = session.name ?? ""
        renameSessionID = session.id
        renameFieldFocused = true
    }
    private func clockText(_ interval: TimeInterval, alwaysShowHours: Bool = false) -> String {
        let seconds = max(0, Int(interval))
        if alwaysShowHours || seconds >= 3_600 {
            return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

}

private struct ResultTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true

        let textView = scrollView.documentView as! NSTextView
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: Layout.small, height: Layout.small)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = textView.maxSize
        textView.textContainer?.widthTracksTextView = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

private enum Layout {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let compactControl: CGFloat = 180
    static let sidebarMinimum: CGFloat = 240
    static let sidebarIdeal: CGFloat = 280
    static let sidebarMaximum: CGFloat = 360
    static let contentMaximum: CGFloat = 920
    static let resultMinimumHeight: CGFloat = 180
    static let resultMaximumHeight: CGFloat = 360
    static let logMaximumHeight: CGFloat = 180
}
