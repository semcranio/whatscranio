import Foundation
import Testing
@testable import WhatsCranio

@Suite("Web link routing")
struct WebLinkRoutingTests {
    @Test("External web links open outside the WhatsApp Web view")
    func externalWebLinks() throws {
        let url = try #require(URL(string: "https://www.fanaticas.com.br/produto"))
        #expect(WebLinkRouting.shouldOpenExternally(url))
    }

    @Test("WhatsApp Web navigation stays in the current session")
    func internalWhatsAppLinks() throws {
        let url = try #require(URL(string: "https://web.whatsapp.com/"))
        #expect(!WebLinkRouting.shouldOpenExternally(url))
    }

    @Test("System link schemes open externally while unsafe schemes do not")
    func systemAndUnsafeSchemes() throws {
        let email = try #require(URL(string: "mailto:contato@example.com"))
        let phone = try #require(URL(string: "tel:+5511989003414"))
        let script = try #require(URL(string: "javascript:alert(1)"))

        #expect(WebLinkRouting.shouldOpenExternally(email))
        #expect(WebLinkRouting.shouldOpenExternally(phone))
        #expect(!WebLinkRouting.shouldOpenExternally(script))
    }
}
