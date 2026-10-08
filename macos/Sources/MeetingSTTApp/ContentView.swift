import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renameSessionID: String?
    @State private var renameDraft = ""
    @State private var deleteSessionID: String?
    @State private var transcriptSearchText = ""
    @State private var transcriptSearchMatches: [NSRange] = []
    @State private var selectedTranscriptMatch = 0
    @FocusState private var renameFieldFocused: Bool
    @FocusState private var transcriptSearchFocused: Bool

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
                            "Select a recording",
                            systemImage: "waveform",
                            description: Text("Start a new recording or select a saved recording on the left.")
                        )
                    }
                    logSection
                }
                .padding(Layout.xLarge)
                .frame(maxWidth: Layout.contentMaximum, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle(model.selectedSession.map(model.sessionTitle) ?? "Meeting STT")
            .overlay(alignment: .bottom) {
                ZStack {
                    if let toast = model.toast {
                        Label(toast, systemImage: "checkmark.circle.fill")
                            .padding(.horizontal, Layout.large)
                            .padding(.vertical, Layout.small)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: Layout.xSmall)
                            .padding(.bottom, Layout.xLarge)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.toast)
                .allowsHitTesting(false)
            }
        }
        .task { await model.start() }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Session name", text: $renameDraft)
                .focused($renameFieldFocused)
            Button("Cancel", role: .cancel) { renameSessionID = nil }
            Button("Save") {
                guard let id = renameSessionID else { return }
                model.renameSession(id: id, name: renameDraft)
                renameSessionID = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("Leave blank to use the default date-based name.")
        }
        .alert("Delete this session?", isPresented: deletePresented) {
            Button("Cancel", role: .cancel) { deleteSessionID = nil }
            Button("Delete", role: .destructive) {
                guard let id = deleteSessionID else { return }
                model.deleteSession(id: id)
                deleteSessionID = nil
            }
        } message: {
            Text("This deletes the recording and its transcripts and notes. This cannot be undone.")
        }
        .onChange(of: transcriptSearchText) { _, _ in updateTranscriptSearch() }
        .onChange(of: model.currentResultText) { _, _ in updateTranscriptSearch() }
        .onChange(of: model.resultKind) { _, _ in updateTranscriptSearch() }
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No saved recordings",
                    systemImage: "waveform.badge.plus",
                    description: Text("Choose an audio source on the right to start your first recording.")
                )
            } else {
                List(selection: $model.selectedSessionID) {
                    ForEach(model.sessions) { session in
                        sessionRow(session)
                            .tag(Optional(session.id))
                            .contextMenu {
                                Button("Rename…") { beginRename(session) }
                                    .disabled(model.isBusy)
                                Button("Delete…", role: .destructive) { deleteSessionID = session.id }
                                    .disabled(model.isBusy)
                            }
                    }
                }
                .onChange(of: model.selectedSessionID) { _, _ in Task { await model.loadSelectedSession() } }
            }
        }
        .navigationTitle("Saved recordings")
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshSessions()
                } label: {
                    Label("Refresh recordings", systemImage: "arrow.clockwise")
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
                    session.transcribed ? "Transcribed" : model.sessionStatus(session),
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
                    Button("Dismiss") { model.dismissError() }
                }
            }
            .accessibilityLabel("Error: \(error)")
        } else if !model.rootPath.isEmpty {
            LabeledContent("Project") {
                Text(model.rootPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var recordingSection: some View {
        GroupBox("Recording") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                Picker("Audio source", selection: $model.captureSource) {
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
                                model.isStartingRecording ? "Preparing…" : (model.isStopping ? "Stopping…" : "Stop recording"),
                                systemImage: "stop.fill"
                            )
                        }
                        .disabled(!model.canStopRecording)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        Button {
                            model.togglePause()
                        } label: {
                            Label(model.isPaused ? "Resume recording" : "Pause", systemImage: model.isPaused ? "record.circle" : "pause.fill")
                        }
                        .disabled(!model.canStopRecording)
                    } else {
                        Button {
                            Task { await model.startRecording() }
                        } label: {
                            Label("Start recording", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartRecording)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    Text(model.activityDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if let notice = model.microphoneNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                if model.isRecordingOrStopping {
                    Grid(alignment: .leading, horizontalSpacing: Layout.large, verticalSpacing: Layout.small) {
                        GridRow {
                            Text("Elapsed time")
                            Text(clockText(model.elapsed, alwaysShowHours: true))
                                .monospacedDigit()
                        }
                        GridRow {
                            Text("File size")
                            Text(ByteCountFormatter.string(fromByteCount: model.recordedBytes, countStyle: .file))
                                .monospacedDigit()
                        }
                        GridRow {
                            Text(model.captureSource == .systemAndMic ? "Input / output level" : (model.captureSource == .device ? "Input level" : "Output level"))
                            HStack(spacing: Layout.small) {
                                ProgressView(value: model.rmsLevel, total: 1)
                                    .frame(minWidth: Layout.compactControl)
                                Text(model.rmsLevel.formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .accessibilityLabel(model.captureSource == .systemAndMic ? "Input / output level" : (model.captureSource == .device ? "Input level" : "Output level"))
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
        case .device, .systemAndMic:
            if model.captureSource == .systemAndMic {
                Text("Record all Mac audio together with your selected microphone.")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Input device") {
                HStack(spacing: Layout.small) {
                    Picker("Input device", selection: $model.selectedDeviceID) {
                        if model.devices.isEmpty {
                            Text("No input devices available").tag(Optional<AudioDeviceID>.none)
                        }
                        ForEach(model.devices) { device in
                            Text(model.deviceTitle(device)).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("Refresh input devices", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("Refresh input devices")
                }
            }
        case .app:
            LabeledContent("Target app") {
                HStack(spacing: Layout.small) {
                    Picker("Target app", selection: $model.selectedAppPID) {
                        if model.apps.isEmpty {
                            Text("No apps available for capture").tag(Optional<pid_t>.none)
                        }
                        ForEach(model.apps) { app in
                            Text(model.appTitle(app)).tag(Optional(app.pid))
                        }
                    }
                    .labelsHidden()
                    Button {
                        Task { await model.refreshApps() }
                    } label: {
                        Label("Refresh apps", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("Refresh apps")
                }
            }
        case .system:
            LabeledContent("Source") {
                Text("All audio playing on this Mac")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionSection(_ session: RecordingSession) -> some View {
        GroupBox("Selected recording") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                LabeledContent("Session") { Text(session.id).textSelection(.enabled) }
                LabeledContent("Status") { Text(model.sessionStatus(session)) }
                if let audioURL = session.audioURL {
                    LabeledContent("File") {
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
                        Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(session.audioURL == nil)

                    Slider(
                        value: Binding(
                            get: { model.playbackPosition },
                            set: { model.seekPlayback(to: $0) }
                        ),
                        in: 0...max(model.playbackDuration, 1)
                    )
                    .accessibilityLabel("Playback position")
                    Text(clockText(model.playbackPosition))
                        .monospacedDigit()
                    Text("/")
                        .foregroundStyle(.secondary)
                    Text(clockText(model.playbackDuration))
                        .monospacedDigit()

                    Spacer()
                    Button("Rename…") { beginRename(session) }
                        .disabled(model.isBusy)
                    Button("Delete…", role: .destructive) { deleteSessionID = session.id }
                        .disabled(model.isBusy)
                }
            }
            .padding(Layout.xSmall)
        }
    }

    private func transcriptionSection(_ session: RecordingSession) -> some View {
        GroupBox("Transcript") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                TextField("Context keywords (comma-separated)", text: $model.context)
                    .disabled(model.isBusy)
                HStack(spacing: Layout.large) {
                    Picker("Speakers", selection: $model.speakerCount) {
                        Text("Auto").tag(Optional<Int>.none)
                        ForEach(1...20, id: \.self) { count in
                            Text("\(count) speakers").tag(Optional(count))
                        }
                    }
                    .frame(maxWidth: Layout.compactControl)
                    TextField("Project", text: $model.project)
                    Toggle("Speaker diarization", isOn: $model.diarize)
                }
                .disabled(model.isBusy)

                HStack(spacing: Layout.small) {
                    if model.isWorkerRunning {
                        Button("Cancel task", role: .cancel) {
                            Task { await model.cancelWorker() }
                        }
                        .keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            Task { await model.transcribe(sessionID: session.id) }
                        } label: {
                            Label(session.transcribed ? "Transcribe again" : "Start transcription", systemImage: "text.waveform")
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
        GroupBox("Results") {
            VStack(alignment: .leading, spacing: Layout.medium) {
                HStack(spacing: Layout.small) {
                    Picker("Result type", selection: $model.resultKind) {
                        ForEach(ResultKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    Spacer()
                    Button("Generate notes") {
                        Task { await model.generateNotes(promptOnly: false) }
                    }
                    .disabled(!model.canGenerateNotes)
                    Button("AI notes") {
                        Task { await model.generateNotes(promptOnly: false, ai: true) }
                    }
                    .disabled(!model.canGenerateNotes)
                    Button("AI summary prompt") {
                        Task { await model.generateNotes(promptOnly: true) }
                    }
                    .disabled(!model.canGenerateNotes)
                    Button {
                        model.copyCurrentResult()
                    } label: {
                        Label("Copy current result", systemImage: "doc.on.doc")
                    }
                    .disabled(model.currentResultText.isEmpty)
                }

                if model.resultKind == .transcript, !model.currentResultText.isEmpty {
                    transcriptSearchBar
                }

                if model.currentResultText.isEmpty {
                    ContentUnavailableView(
                        "No results yet",
                        systemImage: "doc.text",
                        description: Text(model.resultKind.emptyDescription)
                    )
                    .frame(minHeight: Layout.resultMinimumHeight)
                } else {
                    ResultTextView(
                        text: model.currentResultText,
                        matchRanges: model.resultKind == .transcript ? transcriptSearchMatches : [],
                        selectedMatchIndex: selectedTranscriptMatch
                    )
                    .frame(minHeight: Layout.resultMinimumHeight, maxHeight: Layout.resultMaximumHeight)
                }
            }
            .padding(Layout.xSmall)
        }
    }

    private var transcriptSearchBar: some View {
        HStack(spacing: Layout.small) {
            Button { transcriptSearchFocused = true } label: {
                Label("Search transcript", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("f", modifiers: .command)
            .help("Search transcript (⌘F)")
            TextField("Search transcript", text: $transcriptSearchText)
                .textFieldStyle(.plain)
                .focused($transcriptSearchFocused)
                .onSubmit { selectNextTranscriptMatch() }

            if !transcriptSearchText.isEmpty {
                Text(transcriptSearchCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Search results \(transcriptSearchCountText)")

                Button { selectPreviousTranscriptMatch() } label: {
                    Label("Previous match", systemImage: "chevron.up")
                }
                .labelStyle(.iconOnly)
                .disabled(transcriptSearchMatches.isEmpty)

                Button { selectNextTranscriptMatch() } label: {
                    Label("Next match", systemImage: "chevron.down")
                }
                .labelStyle(.iconOnly)
                .disabled(transcriptSearchMatches.isEmpty)

                Button {
                    transcriptSearchText = ""
                    transcriptSearchFocused = true
                } label: {
                    Label("Clear search", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Layout.medium)
        .padding(.vertical, Layout.small)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Layout.small))
    }

    private var transcriptSearchCountText: String {
        guard !transcriptSearchMatches.isEmpty else { return "0 matches" }
        return "\(selectedTranscriptMatch + 1)/\(transcriptSearchMatches.count)"
    }

    private func updateTranscriptSearch() {
        guard model.resultKind == .transcript else {
            transcriptSearchMatches = []
            selectedTranscriptMatch = 0
            return
        }
        transcriptSearchMatches = Self.matchRanges(
            in: model.currentResultText,
            query: transcriptSearchText
        )
        selectedTranscriptMatch = 0
    }

    private func selectPreviousTranscriptMatch() {
        guard !transcriptSearchMatches.isEmpty else { return }
        selectedTranscriptMatch = (selectedTranscriptMatch - 1 + transcriptSearchMatches.count)
            % transcriptSearchMatches.count
    }

    private func selectNextTranscriptMatch() {
        guard !transcriptSearchMatches.isEmpty else { return }
        selectedTranscriptMatch = (selectedTranscriptMatch + 1) % transcriptSearchMatches.count
    }

    private static func matchRanges(in text: String, query: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }

        let source = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)

        while searchRange.length > 0 {
            let match = source.range(of: needle, options: options, range: searchRange)
            guard match.location != NSNotFound else { break }
            ranges.append(match)
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return ranges
    }

    private var logSection: some View {
        DisclosureGroup("Activity log") {
            if model.logLines.isEmpty {
                Text("No activity yet.")
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
    let matchRanges: [NSRange]
    let selectedMatchIndex: Int

    final class Coordinator {
        var text = ""
        var matchRanges: [NSRange] = []
        var selectedMatchIndex = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.text != text
            || coordinator.matchRanges != matchRanges
            || coordinator.selectedMatchIndex != selectedMatchIndex
        else { return }

        if coordinator.text != text {
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textColor = .labelColor
        }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        textView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
        for range in matchRanges {
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.32),
                range: range
            )
        }
        if matchRanges.indices.contains(selectedMatchIndex) {
            let selectedRange = matchRanges[selectedMatchIndex]
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.48),
                range: selectedRange
            )
            textView.scrollRangeToVisible(selectedRange)
        }

        coordinator.text = text
        coordinator.matchRanges = matchRanges
        coordinator.selectedMatchIndex = selectedMatchIndex
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
