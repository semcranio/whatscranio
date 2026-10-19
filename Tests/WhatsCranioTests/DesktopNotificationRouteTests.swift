import Foundation
import Testing
@testable import WhatsCranio

@Suite("Desktop notification routing")
struct DesktopNotificationRouteTests {
    @Test("Preserves the account and conversation target")
    func completeRoute() throws {
        let accountID = UUID()
        let route = try #require(DesktopNotificationRoute(userInfo: [
            "accountID": accountID.uuidString,
            "conversationLabel": "  Tales Lima  ",
            "conversationID": "  tales lima  "
        ]))

        #expect(route == DesktopNotificationRoute(
            accountID: accountID,
            conversationLabel: "Tales Lima",
            conversationID: "tales lima"
        ))
    }

    @Test("Accepts account-only notifications and rejects invalid accounts")
    func accountOnlyAndInvalidRoutes() throws {
        let accountID = UUID()
        let accountOnly = try #require(DesktopNotificationRoute(userInfo: [
            "accountID": accountID.uuidString
        ]))

        #expect(accountOnly.conversationLabel == nil)
        #expect(accountOnly.conversationID == nil)
        #expect(DesktopNotificationRoute(userInfo: ["accountID": "invalid"]) == nil)
    }
}
