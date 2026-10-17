import Foundation
import Testing
@testable import WhatsCranio

struct ScheduledMessageTests {
    private struct LegacyScheduledMessage: Encodable {
        let id: UUID
        let accountID: UUID
        let recipientLabel: String
        let body: String
        let attachmentPaths: [String]
        let scheduledAt: Date
        let status: ScheduledMessageStatus
    }

    @Test("Agendamentos antigos exigem confirmação por padrão")
    func legacyScheduleDefaultsToConfirmation() throws {
        let legacy = LegacyScheduledMessage(
            id: UUID(),
            accountID: UUID(),
            recipientLabel: "Cliente",
            body: "Mensagem antiga",
            attachmentPaths: [],
            scheduledAt: Date(timeIntervalSinceReferenceDate: 123_456),
            status: .pending
        )

        let decoded = try JSONDecoder().decode(
            ScheduledMessage.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(decoded.deliveryMode == .confirmBeforeSending)
    }

    @Test("O modo automático persiste entre reinicializações")
    func automaticModeRoundTrips() throws {
        let original = ScheduledMessage(
            accountID: UUID(),
            recipientLabel: "Cliente automático",
            body: "Mensagem automática",
            attachmentPaths: ["/tmp/anexo.png"],
            scheduledAt: Date(timeIntervalSinceReferenceDate: 654_321),
            status: .sending,
            deliveryMode: .automatic
        )

        let decoded = try JSONDecoder().decode(
            ScheduledMessage.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
        #expect(decoded.deliveryMode == .automatic)
        #expect(decoded.status == .sending)
    }
}
