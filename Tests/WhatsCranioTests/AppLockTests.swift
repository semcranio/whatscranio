import Foundation
import Testing
@testable import WhatsCranio

private final class MemoryLockCredentialStore: LockCredentialStoring {
    var password: Data?

    func loadPassword() throws -> Data? {
        password
    }

    func savePassword(_ data: Data) throws {
        password = data
    }

    func removePassword() throws {
        password = nil
    }
}

struct AppLockTests {
    @Test("Modelo permanece bloqueado após tentativa com senha incorreta")
    @MainActor
    func modelRejectsIncorrectUnlockPassword() {
        let store = MemoryLockCredentialStore()
        store.password = Data("senha-correta".utf8)
        let model = AppModel(lockSecurity: AppLockSecurity(store: store))

        model.lockNow()
        #expect(model.isLocked)
        #expect(!model.unlock(with: "senha-errada"))
        #expect(model.isLocked)
        #expect(model.unlock(with: "senha-correta"))
        #expect(!model.isLocked)
    }

    @Test("Botão de bloqueio encaminha para configuração quando ainda não há senha")
    @MainActor
    func lockWithoutPasswordOpensSettings() {
        let model = AppModel(lockSecurity: AppLockSecurity(store: MemoryLockCredentialStore()))

        model.lockNow()

        #expect(!model.isLocked)
        #expect(model.showingSettings)
    }

    @Test("Senha incorreta nunca valida o desbloqueio")
    func incorrectPasswordDoesNotUnlock() {
        let store = MemoryLockCredentialStore()
        let security = AppLockSecurity(store: store)

        #expect(security.setInitialPassword("cranio123", confirmation: "cranio123") == .success)
        #expect(security.verify("cranio123"))
        #expect(!security.verify("senha-errada"))
    }

    @Test("Troca e remoção exigem a senha atual")
    func changingAndRemovingRequireCurrentPassword() {
        let store = MemoryLockCredentialStore()
        let security = AppLockSecurity(store: store)
        #expect(security.setInitialPassword("senha-inicial", confirmation: "senha-inicial") == .success)

        #expect(security.changePassword(
            current: "incorreta",
            newPassword: "senha-nova",
            confirmation: "senha-nova"
        ) == .currentPasswordIncorrect)
        #expect(security.verify("senha-inicial"))

        #expect(security.changePassword(
            current: "senha-inicial",
            newPassword: "senha-nova",
            confirmation: "senha-nova"
        ) == .success)
        #expect(!security.verify("senha-inicial"))
        #expect(security.verify("senha-nova"))

        #expect(security.removePassword(current: "incorreta") == .currentPasswordIncorrect)
        #expect(security.hasPassword)
        #expect(security.removePassword(current: "senha-nova") == .success)
        #expect(!security.hasPassword)
    }

    @Test("Bloqueio automático respeita o limite configurado")
    func automaticLockHonorsConfiguredDelay() {
        let activity = Date(timeIntervalSinceReferenceDate: 10_000)

        #expect(!AutoLockPolicy.shouldLock(
            enabled: true,
            hasPassword: true,
            inactivityMinutes: 5,
            lastActivity: activity,
            now: activity.addingTimeInterval(299)
        ))
        #expect(AutoLockPolicy.shouldLock(
            enabled: true,
            hasPassword: true,
            inactivityMinutes: 5,
            lastActivity: activity,
            now: activity.addingTimeInterval(300)
        ))
        #expect(!AutoLockPolicy.shouldLock(
            enabled: false,
            hasPassword: true,
            inactivityMinutes: 5,
            lastActivity: activity,
            now: activity.addingTimeInterval(600)
        ))
        #expect(!AutoLockPolicy.shouldLock(
            enabled: true,
            hasPassword: false,
            inactivityMinutes: 5,
            lastActivity: activity,
            now: activity.addingTimeInterval(600)
        ))
    }

    @Test("Senha precisa ter confirmação e no mínimo quatro caracteres")
    func passwordValidation() {
        let security = AppLockSecurity(store: MemoryLockCredentialStore())

        #expect(security.setInitialPassword("123", confirmation: "123") == .passwordTooShort)
        #expect(security.setInitialPassword("1234", confirmation: "4321") == .passwordsDoNotMatch)
        #expect(!security.hasPassword)
    }
}
