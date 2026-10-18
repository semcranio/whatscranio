import AppKit
import Foundation

struct WhatsAppDeepLink: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let webURL: URL
    let phone: String?
    let text: String?

    init?(url: URL, id: UUID = UUID()) {
        guard let source = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = source.scheme?.lowercased()
        else { return nil }

        let host = source.host?.lowercased()
        let normalizedPath = source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let isWhatsAppScheme = scheme == "whatsapp" && (host == "send" || normalizedPath == "send")
        let isAPILink = scheme == "https" && host == "api.whatsapp.com" && normalizedPath == "send"
        let isWebLink = scheme == "https" && host == "web.whatsapp.com" && normalizedPath == "send"
        let isShortLink = scheme == "https" && host == "wa.me"
        guard isWhatsAppScheme || isAPILink || isWebLink || isShortLink else { return nil }

        let sourceItems = source.queryItems ?? []
        let queryPhone = sourceItems.first(where: { $0.name.caseInsensitiveCompare("phone") == .orderedSame })?.value
        let pathPhone = isShortLink ? source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : nil
        let rawPhone = queryPhone ?? pathPhone
        let normalizedPhone = rawPhone?.filter(\.isNumber)
        let resolvedPhone = normalizedPhone?.isEmpty == false ? normalizedPhone : nil
        let resolvedText = sourceItems.first(where: { $0.name.caseInsensitiveCompare("text") == .orderedSame })?.value

        guard resolvedPhone != nil || resolvedText?.isEmpty == false else { return nil }

        var destination = URLComponents()
        destination.scheme = "https"
        destination.host = "web.whatsapp.com"
        destination.path = "/send/"
        destination.queryItems = [
            resolvedPhone.map { URLQueryItem(name: "phone", value: $0) },
            resolvedText.map { URLQueryItem(name: "text", value: $0) },
            URLQueryItem(name: "app_absent", value: "0")
        ].compactMap { $0 }

        guard let webURL = destination.url else { return nil }
        self.id = id
        sourceURL = url
        self.webURL = webURL
        phone = resolvedPhone
        text = resolvedText
    }
}

enum WhatsAppPhoneNumber {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        variants(for: lhs).contains { left in
            variants(for: rhs).contains { right in
                left.count >= 8 && right.count >= 8
                    && (left.hasSuffix(right) || right.hasSuffix(left))
            }
        }
    }

    static func variants(for value: String) -> Set<String> {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return [] }
        var result: Set<String> = [digits]

        // WhatsApp can resolve a Brazilian mobile number with the ninth digit
        // while presenting that same account without it in the Web UI.
        if digits.hasPrefix("55"), digits.count == 13,
           digits[digits.index(digits.startIndex, offsetBy: 4)] == "9" {
            let index = digits.index(digits.startIndex, offsetBy: 4)
            result.insert(String(digits[..<index]) + String(digits[digits.index(after: index)...]))
        } else if digits.hasPrefix("55"), digits.count == 12 {
            let index = digits.index(digits.startIndex, offsetBy: 4)
            result.insert(String(digits[..<index]) + "9" + String(digits[index...]))
        }
        return result
    }
}

enum WhatsAppDeepLinkRoute: Equatable {
    case unavailable
    case open(accountID: UUID)
    case chooseAccount
}

enum WhatsAppDeepLinkRouting {
    static func route(accounts: [WebAccount], preferredAccountID: UUID?) -> WhatsAppDeepLinkRoute {
        guard !accounts.isEmpty else { return .unavailable }
        if accounts.count == 1, let account = accounts.first {
            return .open(accountID: account.id)
        }
        if let preferredAccountID,
           accounts.contains(where: { $0.id == preferredAccountID }) {
            return .open(accountID: preferredAccountID)
        }
        return .chooseAccount
    }
}

@MainActor
final class WhatsAppDeepLinkRouter {
    static let shared = WhatsAppDeepLinkRouter()

    private var queuedURLs: [URL] = []
    private var receiver: ((URL) -> Void)?
    private var lastReceivedURL: String?
    private var lastReceivedAt = Date.distantPast

    func install(receiver: @escaping (URL) -> Void) {
        self.receiver = receiver
        let queued = queuedURLs
        queuedURLs.removeAll()
        queued.forEach(receiver)
    }

    func receive(_ url: URL, now: Date = .now) {
        if lastReceivedURL == url.absoluteString, now.timeIntervalSince(lastReceivedAt) < 1 {
            return
        }
        lastReceivedURL = url.absoluteString
        lastReceivedAt = now

        if let receiver {
            receiver(url)
        } else {
            queuedURLs.append(url)
            if queuedURLs.count > 10 {
                queuedURLs.removeFirst(queuedURLs.count - 10)
            }
        }
    }
}
