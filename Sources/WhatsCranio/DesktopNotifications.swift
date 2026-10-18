import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let whatscranioOpenNotificationAccount = Notification.Name("whatscranio.openNotificationAccount")
}

final class DesktopNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = DesktopNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let accountIDString = response.notification.request.content.userInfo["accountID"] as? String,
              let accountID = UUID(uuidString: accountIDString) else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .whatscranioOpenNotificationAccount,
                object: accountID
            )
        }
    }
}

@MainActor
enum DesktopNotificationService {
    static func configure() {
        UNUserNotificationCenter.current().delegate = DesktopNotificationDelegate.shared
    }

    static func requestAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    static func deliver(
        account: WebAccount,
        sender: String,
        preview: String,
        conversationID: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = sender.isEmpty ? "Nova mensagem" : sender
        content.subtitle = account.name
        content.body = preview.isEmpty ? "Você recebeu uma nova mensagem no WhatsApp." : preview
        content.sound = .default
        content.userInfo = ["accountID": account.id.uuidString]

        let safeConversationID = conversationID
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let identifier = "message.\(account.id.uuidString).\(safeConversationID).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
