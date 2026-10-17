import Foundation

enum LocalStore {
    private static let accountsKey = "whatscranio.accounts.v1"
    private static let templatesKey = "whatscranio.templates.v1"
    private static let schedulesKey = "whatscranio.schedules.v1"
    private static let macroQueuesKey = "whatscranio.macroQueues.v1"

    static func loadAccounts() -> [WebAccount] {
        load([WebAccount].self, key: accountsKey) ?? []
    }

    static func saveAccounts(_ value: [WebAccount]) {
        save(value, key: accountsKey)
    }

    static func loadTemplates() -> [QuickMessageTemplate] {
        load([QuickMessageTemplate].self, key: templatesKey) ?? []
    }

    static func saveTemplates(_ value: [QuickMessageTemplate]) {
        save(value, key: templatesKey)
    }

    static func loadSchedules() -> [ScheduledMessage] {
        load([ScheduledMessage].self, key: schedulesKey) ?? []
    }

    static func saveSchedules(_ value: [ScheduledMessage]) {
        save(value, key: schedulesKey)
    }

    static func loadMacroQueues() -> [MessageMacroQueue] {
        load([MessageMacroQueue].self, key: macroQueuesKey) ?? []
    }

    static func saveMacroQueues(_ value: [MessageMacroQueue]) {
        save(value, key: macroQueuesKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
