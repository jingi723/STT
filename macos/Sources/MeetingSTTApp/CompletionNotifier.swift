import AppKit
import Foundation
import UserNotifications

final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CompletionNotifier()

    private let center: UNUserNotificationCenter

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyTranscriptionCompleted(sessionTitle: String, sessionID: String) async {
        let settings = await center.notificationSettings()
        guard Self.canNotify(settings.authorizationStatus) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transcription complete"
        content.body = "The transcript for \(sessionTitle) is ready."
        content.sound = .default
        content.userInfo = ["session_id": sessionID]

        let request = UNNotificationRequest(
            identifier: "transcription-complete-\(sessionID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private static func canNotify(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
