import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let whatscranioOpenNotification = Notification.Name("whatscranio.openNotification")
}

struct DesktopNotificationRoute: Equatable {
    let accountID: UUID
    let conversationLabel: String?
    let conversationID: String?

    init(accountID: UUID, conversationLabel: String? = nil, conversationID: String? = nil) {
        self.accountID = accountID
        self.conversationLabel = conversationLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.conversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let accountIDString = userInfo["accountID"] as? String,
              let accountID = UUID(uuidString: accountIDString) else { return nil }
        self.init(
            accountID: accountID,
            conversationLabel: userInfo["conversationLabel"] as? String,
            conversationID: userInfo["conversationID"] as? String
        )
    }
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = DesktopNotificationRoute(userInfo: response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .whatscranioOpenNotification, object: route)
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
        content.userInfo = [
            "accountID": account.id.uuidString,
            "conversationID": conversationID,
            "conversationLabel": sender
        ]
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
        let content = UNMutableNotificationContent()
        content.title = "Notificação de teste"
        content.subtitle = account.name
        content.body = "As novas mensagens aparecerão aqui com remetente e conteúdo."
        content.sound = .default
        content.userInfo = ["accountID": account.id.uuidString]
        content.threadIdentifier = account.id.uuidString
        content.interruptionLevel = .active
        content.relevanceScore = 1
        let request = UNNotificationRequest(
            identifier: "message.\(account.id.uuidString).notification-test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
