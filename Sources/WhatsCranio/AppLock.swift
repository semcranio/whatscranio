import Foundation
import Security

protocol LockCredentialStoring {
    func loadPassword() throws -> Data?
    func savePassword(_ data: Data) throws
    func removePassword() throws
}

enum LockCredentialError: Error {
    case keychain(OSStatus)
}

struct KeychainLockCredentialStore: LockCredentialStoring {
    private let service = "dev.taleslima.whatscranio.lock"
    private let account = "app-lock-password"

    func loadPassword() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LockCredentialError.keychain(status) }
        return result as? Data
    }

    func savePassword(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw LockCredentialError.keychain(updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw LockCredentialError.keychain(addStatus) }
    }

    func removePassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LockCredentialError.keychain(status)
        }
    }
}

enum LockPasswordChangeResult: Equatable {
    case success
    case passwordTooShort
    case passwordsDoNotMatch
    case currentPasswordIncorrect
    case storageFailure
}

struct AppLockSecurity {
    private let store: any LockCredentialStoring

    init(store: any LockCredentialStoring = KeychainLockCredentialStore()) {
        self.store = store
    }

    var hasPassword: Bool {
        ((try? store.loadPassword()) ?? nil) != nil
    }

    func verify(_ password: String) -> Bool {
        guard let stored = try? store.loadPassword() else { return false }
        return constantTimeEqual(stored, Data(password.utf8))
    }

    func setInitialPassword(_ password: String, confirmation: String) -> LockPasswordChangeResult {
        guard password.count >= 4 else { return .passwordTooShort }
        guard password == confirmation else { return .passwordsDoNotMatch }
        do {
            try store.savePassword(Data(password.utf8))
            return .success
        } catch {
            return .storageFailure
        }
    }

    func changePassword(current: String, newPassword: String, confirmation: String) -> LockPasswordChangeResult {
        guard verify(current) else { return .currentPasswordIncorrect }
        return setInitialPassword(newPassword, confirmation: confirmation)
    }

    func removePassword(current: String) -> LockPasswordChangeResult {
        guard verify(current) else { return .currentPasswordIncorrect }
        do {
            try store.removePassword()
            return .success
        } catch {
            return .storageFailure
        }
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { partial, pair in
            partial | (pair.0 ^ pair.1)
        } == 0
    }
}

enum AutoLockPolicy {
    static func shouldLock(
        enabled: Bool,
        hasPassword: Bool,
        inactivityMinutes: Int,
        lastActivity: Date,
        now: Date
    ) -> Bool {
        guard enabled, hasPassword else { return false }
        let timeout = TimeInterval(max(inactivityMinutes, 1) * 60)
        return now.timeIntervalSince(lastActivity) >= timeout
    }
}
