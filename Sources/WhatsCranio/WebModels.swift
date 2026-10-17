import Foundation

struct WebAccount: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let dataStoreID: UUID
    var tint: String

    init(id: UUID = UUID(), name: String, dataStoreID: UUID = UUID(), tint: String = "1DAA82") {
        self.id = id
        self.name = name
        self.dataStoreID = dataStoreID
        self.tint = tint
    }
}

struct QuickMessageTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var body: String
    var category: String
    var attachmentPaths: [String]

    init(id: UUID = UUID(), title: String, body: String, category: String = "", attachmentPaths: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.category = category
        self.attachmentPaths = attachmentPaths
    }

    var categoryLabel: String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sem categoria" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, category, attachmentPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        attachmentPaths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths) ?? []
    }
}

struct MessageMacroQueue: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var templateIDs: [UUID]
    var intervalSeconds: Double

    init(
        id: UUID = UUID(),
        name: String,
        templateIDs: [UUID] = [],
        intervalSeconds: Double = 1.5
    ) {
        self.id = id
        self.name = name
        self.templateIDs = templateIDs
        self.intervalSeconds = intervalSeconds
    }
}

struct QueuedMessagePayload: Hashable {
    let title: String
    let body: String
    let attachmentPaths: [String]
}

enum MessageQueueResult: Equatable {
    case success
    case cancelled
    case failure(String)
}

struct MacroQueueRun: Equatable {
    enum State: Equatable {
        case running
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let accountID: UUID
    let queueName: String
    let recipientLabel: String
    var currentIndex: Int
    let total: Int
    var currentTitle: String
    var state: State
    var detail: String
}

enum ScheduledMessageStatus: String, Codable, CaseIterable {
    case pending
    case ready
    case sending
    case prepared
    case sent
    case cancelled

    var label: String {
        switch self {
        case .pending: "Agendada"
        case .ready: "Pronta"
        case .sending: "Enviando"
        case .prepared: "Preparada"
        case .sent: "Enviada"
        case .cancelled: "Cancelada"
        }
    }
}

enum ScheduledDeliveryMode: String, Codable, CaseIterable, Identifiable {
    case confirmBeforeSending
    case automatic

    var id: Self { self }

    var label: String {
        switch self {
        case .confirmBeforeSending: "Confirmar antes"
        case .automatic: "Enviar automaticamente"
        }
    }
}

struct ScheduledMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var accountID: UUID
    var recipientLabel: String
    var body: String
    var attachmentPaths: [String]
    var scheduledAt: Date
    var status: ScheduledMessageStatus
    var deliveryMode: ScheduledDeliveryMode

    init(
        id: UUID = UUID(),
        accountID: UUID,
        recipientLabel: String,
        body: String,
        attachmentPaths: [String],
        scheduledAt: Date,
        status: ScheduledMessageStatus = .pending,
        deliveryMode: ScheduledDeliveryMode = .confirmBeforeSending
    ) {
        self.id = id
        self.accountID = accountID
        self.recipientLabel = recipientLabel
        self.body = body
        self.attachmentPaths = attachmentPaths
        self.scheduledAt = scheduledAt
        self.status = status
        self.deliveryMode = deliveryMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, recipientLabel, body, attachmentPaths, scheduledAt, status, deliveryMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        recipientLabel = try container.decode(String.self, forKey: .recipientLabel)
        body = try container.decode(String.self, forKey: .body)
        attachmentPaths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths) ?? []
        scheduledAt = try container.decode(Date.self, forKey: .scheduledAt)
        status = try container.decode(ScheduledMessageStatus.self, forKey: .status)
        deliveryMode = try container.decodeIfPresent(ScheduledDeliveryMode.self, forKey: .deliveryMode) ?? .confirmBeforeSending
    }
}
