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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let accountIDString = response.notification.request.content.userInfo["accountID"] as? String,
              let accountID = UUID(uuidString: accountIDString) else {
            completionHandler()
            return
        }
        completionHandler()
        Task { @MainActor in
            NotificationCenter.default.post(name: .whatscranioOpenNotificationAccount, object: accountID)
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
        content.threadIdentifier = account.id.uuidString
        content.interruptionLevel = .active
        content.relevanceScore = 1

        let safeConversationID = conversationID
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let identifier = "message.\(account.id.uuidString).\(safeConversationID).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func deliverTest(account: WebAccount) {
        deliver(
            account: account,
            sender: "Notificação de teste",
            preview: "As novas mensagens aparecerão aqui com remetente e conteúdo.",
            conversationID: "whatscranio-notification-test"
        )
    }
}
