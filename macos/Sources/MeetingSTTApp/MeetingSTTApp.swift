import AppKit
import SwiftUI

@main
@MainActor
struct MeetingSTTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("회의 전사", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1_080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false
    private var hasReplied = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.requiresTerminationCleanup else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }

        isTerminating = true
        Task {
            await model.shutdown()
            replyToTermination()
        }
        Task {
            try? await Task.sleep(for: .seconds(12))
            replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !hasReplied else { return }
        hasReplied = true
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
