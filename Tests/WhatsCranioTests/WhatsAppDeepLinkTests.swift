import Foundation
import Testing
@testable import WhatsCranio

struct WhatsAppDeepLinkTests {
    @Test("Converte whatsapp:// em uma URL do WhatsApp Web preservando telefone e texto")
    func convertsCustomScheme() throws {
        let source = try #require(URL(string: "whatsapp://send?phone=%2B55%20(64)%2098454-6500&text=Ol%C3%A1%20%2AF%C3%A1tima%2A"))
        let link = try #require(WhatsAppDeepLink(url: source))
        let destination = try #require(URLComponents(url: link.webURL, resolvingAgainstBaseURL: false))

        #expect(link.phone == "5564984546500")
        #expect(link.text == "Olá *Fátima*")
        #expect(destination.scheme == "https")
        #expect(destination.host == "web.whatsapp.com")
        #expect(destination.path == "/send/")
        #expect(destination.queryItems?.first(where: { $0.name == "phone" })?.value == "5564984546500")
        #expect(destination.queryItems?.first(where: { $0.name == "text" })?.value == "Olá *Fátima*")
    }

    @Test("Aceita o formato HTTPS usado pela API do WhatsApp")
    func acceptsAPILink() throws {
        let source = try #require(URL(string: "https://api.whatsapp.com/send?phone=5511989003414&text=Teste"))
        let link = try #require(WhatsAppDeepLink(url: source))

        #expect(link.phone == "5511989003414")
        #expect(link.text == "Teste")
    }

    @Test("Aceita links curtos wa.me")
    func acceptsShortLink() throws {
        let source = try #require(URL(string: "https://wa.me/5511989003414?text=Oi"))
        let link = try #require(WhatsAppDeepLink(url: source))

        #expect(link.phone == "5511989003414")
        #expect(link.text == "Oi")
    }

    @Test("Rejeita URLs que não pertencem ao fluxo de conversa do WhatsApp")
    func rejectsUnsupportedURL() throws {
        let source = try #require(URL(string: "https://example.com/send?phone=5511989003414"))
        #expect(WhatsAppDeepLink(url: source) == nil)
    }

    @Test("Uma conta abre diretamente e várias contas exigem escolha")
    func routesByAccountCount() {
        let first = WebAccount(name: "Primeira")
        let second = WebAccount(name: "Segunda")

        #expect(WhatsAppDeepLinkRouting.route(accounts: [], preferredAccountID: nil) == .unavailable)
        #expect(WhatsAppDeepLinkRouting.route(accounts: [first], preferredAccountID: nil) == .open(accountID: first.id))
        #expect(WhatsAppDeepLinkRouting.route(accounts: [first, second], preferredAccountID: nil) == .chooseAccount)
    }

    @Test("A conta padrão é identificada por UUID e não pela posição")
    func routesToStablePreferredAccount() {
        let first = WebAccount(name: "Primeira")
        let preferred = WebAccount(name: "Preferida")

        #expect(
            WhatsAppDeepLinkRouting.route(
                accounts: [preferred, first],
                preferredAccountID: preferred.id
            ) == .open(accountID: preferred.id)
        )
        #expect(
            WhatsAppDeepLinkRouting.route(
                accounts: [first],
                preferredAccountID: preferred.id
            ) == .open(accountID: first.id)
        )
    }

    @Test("Reconhece números brasileiros com ou sem o nono dígito exibido")
    func matchesBrazilianNinthDigitVariant() {
        #expect(WhatsAppPhoneNumber.matches("5564984546500", "+55 64 8454-6500"))
        #expect(WhatsAppPhoneNumber.matches("+55 11 98900-3414", "5511989003414"))
        #expect(!WhatsAppPhoneNumber.matches("5564984546500", "+55 64 8454-6501"))
    }
}
