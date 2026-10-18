import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedAccountID: UUID {
        didSet { UserDefaults.standard.set(selectedAccountID.uuidString, forKey: "whatscranio.selectedAccountID") }
    }
    @Published private(set) var isLocked = false
    @Published private(set) var hasLockPassword: Bool
    @Published var autoLockEnabled: Bool {
        didSet { UserDefaults.standard.set(autoLockEnabled, forKey: "whatscranio.autoLockEnabled") }
    }
    @Published var autoLockMinutes: Int {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "whatscranio.autoLockMinutes") }
    }
    @Published var showingSettings = false
    @Published var showingAddAccount = false
    @Published var showingAutomationCenter = false
    @Published var showingDonation = false
    @Published var pendingWhatsAppLink: WhatsAppDeepLink?
    @Published var deepLinkErrorMessage: String?
    @Published private(set) var preferredDeepLinkAccountID: UUID?
    @Published private(set) var isDefaultWhatsAppLinkHandler = false
    @Published var defaultLinkHandlerFeedback: String?
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "whatscranio.notificationsEnabled") }
    }
    @Published var messageNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(messageNotificationsEnabled, forKey: "whatscranio.messageNotificationsEnabled")
            if messageNotificationsEnabled {
                DesktopNotificationService.requestAuthorization()
            }
        }
    }
    @Published var accounts: [WebAccount]
    @Published var templates: [QuickMessageTemplate]
    @Published var scheduledMessages: [ScheduledMessage]
    @Published var macroQueues: [MessageMacroQueue]
    @Published var activeMacroQueueRun: MacroQueueRun?
    @Published private(set) var activeScheduledSendID: UUID?
    @Published private(set) var unreadMessagesByAccount: [UUID: Int] = [:]
    private let lockSecurity: AppLockSecurity
    private var lastUserActivity = Date()
    private var activityMonitor: Any?
    private var deferredWhatsAppLink: WhatsAppDeepLink?

    init(lockSecurity: AppLockSecurity = AppLockSecurity()) {
        self.lockSecurity = lockSecurity
        hasLockPassword = lockSecurity.hasPassword
        let storedAutoLockEnabled = UserDefaults.standard.object(forKey: "whatscranio.autoLockEnabled") as? Bool ?? false
        autoLockEnabled = storedAutoLockEnabled && lockSecurity.hasPassword
        autoLockMinutes = min(max(UserDefaults.standard.integer(forKey: "whatscranio.autoLockMinutes"), 1), 120)
        if UserDefaults.standard.object(forKey: "whatscranio.autoLockMinutes") == nil {
            autoLockMinutes = 5
        }
        notificationsEnabled = UserDefaults.standard.object(forKey: "whatscranio.notificationsEnabled") as? Bool ?? true
        messageNotificationsEnabled = UserDefaults.standard.object(forKey: "whatscranio.messageNotificationsEnabled") as? Bool ?? true
        let storedAccounts = LocalStore.loadAccounts()
        let resolvedAccounts = storedAccounts.isEmpty ? [
            WebAccount(name: "Conta principal", tint: "1DAA82"),
            WebAccount(name: "Conta comercial", tint: "5B8DEF")
        ] : storedAccounts
        accounts = resolvedAccounts
        let storedSelectedID = UserDefaults.standard.string(forKey: "whatscranio.selectedAccountID").flatMap(UUID.init(uuidString:))
        if let storedSelectedID, resolvedAccounts.contains(where: { $0.id == storedSelectedID }) {
            selectedAccountID = storedSelectedID
        } else {
            selectedAccountID = resolvedAccounts[0].id
        }
        let storedDeepLinkAccountID = UserDefaults.standard
            .string(forKey: "whatscranio.preferredDeepLinkAccountID")
            .flatMap(UUID.init(uuidString:))
        if let storedDeepLinkAccountID,
           resolvedAccounts.contains(where: { $0.id == storedDeepLinkAccountID }) {
            preferredDeepLinkAccountID = storedDeepLinkAccountID
        } else {
            preferredDeepLinkAccountID = nil
            UserDefaults.standard.removeObject(forKey: "whatscranio.preferredDeepLinkAccountID")
        }
        pendingWhatsAppLink = nil
        deepLinkErrorMessage = nil
        defaultLinkHandlerFeedback = nil

        let storedTemplates = LocalStore.loadTemplates()
        templates = storedTemplates.isEmpty ? [
            QuickMessageTemplate(title: "Saudação", body: "Olá! Como posso ajudar?", category: "Atendimento"),
            QuickMessageTemplate(title: "Retorno", body: "Recebi sua mensagem e retorno assim que possível.", category: "Atendimento"),
            QuickMessageTemplate(title: "Orçamento", body: "Olá! Segue o orçamento solicitado. Se tiver dúvidas, estou à disposição.", category: "Vendas")
        ] : storedTemplates
        var storedSchedules = LocalStore.loadSchedules()
        let recoveredInterruptedSend = storedSchedules.contains { $0.status == .sending }
        for index in storedSchedules.indices where storedSchedules[index].status == .sending {
            storedSchedules[index].status = .pending
        }
        scheduledMessages = storedSchedules
        macroQueues = LocalStore.loadMacroQueues()
        activeMacroQueueRun = nil
        activeScheduledSendID = nil
        LocalStore.saveAccounts(accounts)
        LocalStore.saveTemplates(templates)
        if recoveredInterruptedSend { LocalStore.saveSchedules(scheduledMessages) }
        refreshDueSchedules(executeAutomatic: false)
    }

    var totalUnreadMessages: Int {
        unreadMessagesByAccount.values.reduce(0, +)
    }

    func unreadMessages(for accountID: UUID) -> Int {
        unreadMessagesByAccount[accountID, default: 0]
    }

    func updateUnreadMessages(_ count: Int, for accountID: UUID) {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        unreadMessagesByAccount[accountID] = max(0, count)
        refreshUnreadBadge()
    }

    func handleIncomingMessage(
        accountID: UUID,
        sender: String,
        preview: String,
        conversationID: String
    ) {
        guard messageNotificationsEnabled,
              let account = accounts.first(where: { $0.id == accountID }) else { return }
        DesktopNotificationService.deliver(
            account: account,
            sender: sender,
            preview: preview,
            conversationID: conversationID
        )
    }

    func openAccountFromNotification(_ accountID: UUID) {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        selectedAccountID = accountID
        showingAutomationCenter = false
        showingAddAccount = false
        showingSettings = false
        showingDonation = false
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "WhatsCrânio" })?.makeKeyAndOrderFront(nil)
    }

    func startActivityMonitoring() {
        guard activityMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.recordUserActivity()
            }
            return event
        }
    }

    func startDeepLinkHandling() {
        WhatsAppDeepLinkRouter.shared.install { [weak self] url in
            self?.receiveWhatsAppLink(url)
        }
        refreshDefaultWhatsAppLinkHandler()
    }

    func receiveWhatsAppLink(_ url: URL) {
        guard let link = WhatsAppDeepLink(url: url) else {
            deepLinkErrorMessage = "O link recebido não é um endereço válido para iniciar uma conversa no WhatsApp."
            bringMainWindowForward()
            return
        }

        bringMainWindowForward()
        if isLocked {
            deferredWhatsAppLink = link
            return
        }
        routeWhatsAppLink(link)
    }

    func openPendingWhatsAppLink(in accountID: UUID, rememberAccount: Bool) {
        guard let link = pendingWhatsAppLink,
              let account = accounts.first(where: { $0.id == accountID })
        else { return }

        if rememberAccount {
            preferredDeepLinkAccountID = account.id
            UserDefaults.standard.set(account.id.uuidString, forKey: "whatscranio.preferredDeepLinkAccountID")
        }
        pendingWhatsAppLink = nil
        openWhatsAppLink(link, in: account)
    }

    func cancelPendingWhatsAppLink() {
        pendingWhatsAppLink = nil
    }

    func clearPreferredDeepLinkAccount() {
        preferredDeepLinkAccountID = nil
        UserDefaults.standard.removeObject(forKey: "whatscranio.preferredDeepLinkAccountID")
    }

    func refreshDefaultWhatsAppLinkHandler() {
        guard let probeURL = URL(string: "whatsapp://send?phone=1") else { return }
        let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL)
        isDefaultWhatsAppLinkHandler = handlerURL?.resolvingSymlinksInPath().standardizedFileURL
            == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func makeDefaultWhatsAppLinkHandler() {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: "whatsapp"
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.defaultLinkHandlerFeedback = "Não foi possível alterar o aplicativo padrão: \(error.localizedDescription)"
                } else {
                    self.defaultLinkHandlerFeedback = "O WhatsCrânio agora é o aplicativo padrão para links do WhatsApp."
                }
                self.refreshDefaultWhatsAppLinkHandler()
            }
        }
    }

    var preferredDeepLinkAccount: WebAccount? {
        guard let preferredDeepLinkAccountID else { return nil }
        return accounts.first(where: { $0.id == preferredDeepLinkAccountID })
    }

    func stopActivityMonitoring() {
        guard let activityMonitor else { return }
        NSEvent.removeMonitor(activityMonitor)
        self.activityMonitor = nil
    }

    func recordUserActivity(at date: Date = .now) {
        guard !isLocked else { return }
        lastUserActivity = date
    }

    func evaluateAutoLock(at date: Date = .now) {
        guard !isLocked else { return }
        if AutoLockPolicy.shouldLock(
            enabled: autoLockEnabled,
            hasPassword: hasLockPassword,
            inactivityMinutes: autoLockMinutes,
            lastActivity: lastUserActivity,
            now: date
        ) {
            lockNow()
        }
    }

    func lockNow() {
        guard hasLockPassword else {
            showingAutomationCenter = false
            showingAddAccount = false
            showingSettings = true
            showingDonation = false
            return
        }
        showingAutomationCenter = false
        showingAddAccount = false
        showingSettings = false
        showingDonation = false
        if let pendingWhatsAppLink {
            deferredWhatsAppLink = pendingWhatsAppLink
            self.pendingWhatsAppLink = nil
        }
        isLocked = true
    }

    func unlock(with password: String) -> Bool {
        guard lockSecurity.verify(password) else { return false }
        isLocked = false
        recordUserActivity()
        if let deferredWhatsAppLink {
            self.deferredWhatsAppLink = nil
            routeWhatsAppLink(deferredWhatsAppLink)
        }
        return true
    }

    func setInitialLockPassword(_ password: String, confirmation: String) -> LockPasswordChangeResult {
        let result = lockSecurity.setInitialPassword(password, confirmation: confirmation)
        if result == .success {
            hasLockPassword = true
            recordUserActivity()
        }
        return result
    }

    func changeLockPassword(
        current: String,
        newPassword: String,
        confirmation: String
    ) -> LockPasswordChangeResult {
        let result = lockSecurity.changePassword(
            current: current,
            newPassword: newPassword,
            confirmation: confirmation
        )
        if result == .success {
            hasLockPassword = true
            recordUserActivity()
        }
        return result
    }

    func removeLockPassword(current: String) -> LockPasswordChangeResult {
        let result = lockSecurity.removePassword(current: current)
        if result == .success {
            hasLockPassword = false
            autoLockEnabled = false
            isLocked = false
            recordUserActivity()
        }
        return result
    }

    func addAccount(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let colors = ["1DAA82", "5B8DEF", "E58A3B", "8F6AD7", "D45D79"]
        let account = WebAccount(name: cleanName, tint: colors[accounts.count % colors.count])
        accounts.append(account)
        LocalStore.saveAccounts(accounts)
        selectedAccountID = account.id
    }

    @discardableResult
    func updateAccount(_ account: WebAccount, name: String, tint: String) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTint = tint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .uppercased()
        guard !cleanName.isEmpty,
              cleanTint.count == 6,
              cleanTint.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789ABCDEF").contains),
              let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            return false
        }

        var updatedAccount = accounts[index]
        updatedAccount.name = cleanName
        updatedAccount.tint = cleanTint
        accounts[index] = updatedAccount
        LocalStore.saveAccounts(accounts)
        return true
    }

    func removeAccount(_ account: WebAccount) {
        guard accounts.count > 1 else { return }
        accounts.removeAll { $0.id == account.id }
        unreadMessagesByAccount[account.id] = nil
        refreshUnreadBadge()
        scheduledMessages.removeAll { $0.accountID == account.id }
        LocalStore.saveAccounts(accounts)
        LocalStore.saveSchedules(scheduledMessages)
        WebSessionPool.shared.remove(account: account)
        if preferredDeepLinkAccountID == account.id {
            clearPreferredDeepLinkAccount()
        }
        selectedAccountID = accounts[0].id
    }

    private func refreshUnreadBadge() {
        NSApp.dockTile.badgeLabel = totalUnreadMessages > 0 ? String(totalUnreadMessages) : nil
    }

    private func routeWhatsAppLink(_ link: WhatsAppDeepLink) {
        let wasShowingSheet = showingAutomationCenter || showingAddAccount || showingSettings || showingDonation
        showingAutomationCenter = false
        showingAddAccount = false
        showingSettings = false
        showingDonation = false

        switch WhatsAppDeepLinkRouting.route(
            accounts: accounts,
            preferredAccountID: preferredDeepLinkAccountID
        ) {
        case .unavailable:
            deepLinkErrorMessage = "Nenhuma conta do WhatsApp está configurada."
        case .open(let accountID):
            guard let account = accounts.first(where: { $0.id == accountID }) else { return }
            openWhatsAppLink(link, in: account)
        case .chooseAccount:
            if wasShowingSheet {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, !self.isLocked else { return }
                    self.pendingWhatsAppLink = link
                }
            } else {
                pendingWhatsAppLink = link
            }
        }
    }

    private func openWhatsAppLink(_ link: WhatsAppDeepLink, in account: WebAccount) {
        selectedAccountID = account.id
        let session = WebSessionPool.shared.session(for: account)
        session.openWhatsAppLink(link)
        bringMainWindowForward()
    }

    private func bringMainWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        let mainWindow = NSApp.windows.first(where: { window in
            window.canBecomeKey && !(window is NSPanel) && window.title.contains("WhatsCrânio")
        }) ?? NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) })
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func saveTemplate(_ template: QuickMessageTemplate) {
        var normalizedTemplate = template
        normalizedTemplate.title = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedTemplate.category = template.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = templates.firstIndex(where: { $0.id == normalizedTemplate.id }) {
            templates[index] = normalizedTemplate
        } else {
            templates.append(normalizedTemplate)
        }
        LocalStore.saveTemplates(templates)
    }

    var templateCategories: [String] {
        Array(Set(templates.map(\.categoryLabel)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func deleteTemplate(_ template: QuickMessageTemplate) {
        templates.removeAll { $0.id == template.id }
        for index in macroQueues.indices {
            macroQueues[index].templateIDs.removeAll { $0 == template.id }
        }
        LocalStore.saveTemplates(templates)
        LocalStore.saveMacroQueues(macroQueues)
    }

    func saveMacroQueue(_ queue: MessageMacroQueue) {
        var normalized = queue
        normalized.name = queue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.templateIDs = queue.templateIDs.filter { templateID in
            templates.contains(where: { $0.id == templateID })
        }
        normalized.intervalSeconds = min(max(queue.intervalSeconds, 0.5), 30)
        if let index = macroQueues.firstIndex(where: { $0.id == normalized.id }) {
            macroQueues[index] = normalized
        } else {
            macroQueues.append(normalized)
        }
        LocalStore.saveMacroQueues(macroQueues)
    }

    func deleteMacroQueue(_ queue: MessageMacroQueue) {
        macroQueues.removeAll { $0.id == queue.id }
        LocalStore.saveMacroQueues(macroQueues)
    }

    func templates(for queue: MessageMacroQueue) -> [QuickMessageTemplate] {
        queue.templateIDs.compactMap { templateID in
            templates.first(where: { $0.id == templateID })
        }
    }

    func runMacroQueue(_ queue: MessageMacroQueue, accountID: UUID, recipientLabel: String) {
        guard activeMacroQueueRun == nil,
              activeScheduledSendID == nil,
              let account = accounts.first(where: { $0.id == accountID })
        else { return }

        let target = recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let selectedTemplates = templates(for: queue)
        guard !selectedTemplates.isEmpty, selectedTemplates.count == queue.templateIDs.count else { return }
        let payloads = selectedTemplates.map {
            QueuedMessagePayload(title: $0.title, body: $0.body, attachmentPaths: $0.attachmentPaths)
        }
        let runID = UUID()
        activeMacroQueueRun = MacroQueueRun(
            id: runID,
            accountID: accountID,
            queueName: queue.name,
            recipientLabel: target,
            currentIndex: 0,
            total: payloads.count,
            currentTitle: payloads[0].title,
            state: .running,
            detail: "Abrindo o contato \(target)"
        )
        selectedAccountID = accountID
        showingAutomationCenter = false
        let session = WebSessionPool.shared.session(for: account)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            session.activateChat(named: target) { [weak self] activated in
                guard let self, self.activeMacroQueueRun?.id == runID else { return }
                guard activated else {
                    self.activeMacroQueueRun?.state = .failed
                    self.activeMacroQueueRun?.detail = "Não foi possível abrir o contato “\(target)”. Nenhuma mensagem foi enviada."
                    self.startNextAutomaticScheduleIfNeeded()
                    return
                }
                session.runMessageQueue(
                    payloads,
                    intervalSeconds: queue.intervalSeconds,
                    progress: { [weak self] index, title in
                        guard let self, self.activeMacroQueueRun?.id == runID else { return }
                        self.activeMacroQueueRun?.currentIndex = index
                        self.activeMacroQueueRun?.currentTitle = title
                        self.activeMacroQueueRun?.detail = "Enviando mensagem \(index + 1) de \(payloads.count)"
                    },
                    completion: { [weak self] result in
                        guard let self, self.activeMacroQueueRun?.id == runID else { return }
                        switch result {
                        case .success:
                            self.activeMacroQueueRun?.state = .completed
                            self.activeMacroQueueRun?.currentIndex = payloads.count
                            self.activeMacroQueueRun?.detail = "Todas as mensagens foram enviadas"
                        case .cancelled:
                            self.activeMacroQueueRun?.state = .cancelled
                            self.activeMacroQueueRun?.detail = "Fila interrompida"
                        case .failure(let reason):
                            self.activeMacroQueueRun?.state = .failed
                            self.activeMacroQueueRun?.detail = reason
                        }
                        self.startNextAutomaticScheduleIfNeeded()
                    }
                )
            }
        }
    }

    func cancelMacroQueue() {
        guard let run = activeMacroQueueRun,
              run.state == .running,
              let account = accounts.first(where: { $0.id == run.accountID })
        else { return }
        WebSessionPool.shared.session(for: account).cancelMessageQueue()
    }

    func dismissMacroQueueRun() {
        guard activeMacroQueueRun?.state != .running else { return }
        activeMacroQueueRun = nil
    }

    func scheduleMessage(
        accountID: UUID,
        recipientLabel: String,
        body: String,
        attachmentPaths: [String],
        date: Date,
        deliveryMode: ScheduledDeliveryMode
    ) {
        let target = recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let message = ScheduledMessage(
            accountID: accountID,
            recipientLabel: target,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentPaths: attachmentPaths,
            scheduledAt: date,
            deliveryMode: deliveryMode
        )
        scheduledMessages.append(message)
        LocalStore.saveSchedules(scheduledMessages)
        scheduleNotification(for: message)
    }

    func refreshDueSchedules(executeAutomatic: Bool = true) {
        var changed = false
        for index in scheduledMessages.indices where
            scheduledMessages[index].status == .pending
            && scheduledMessages[index].deliveryMode == .confirmBeforeSending
            && scheduledMessages[index].scheduledAt <= .now {
            scheduledMessages[index].status = .ready
            changed = true
        }
        if changed { LocalStore.saveSchedules(scheduledMessages) }
        if executeAutomatic { startNextAutomaticScheduleIfNeeded() }
    }

    private func startNextAutomaticScheduleIfNeeded() {
        guard activeScheduledSendID == nil,
              activeMacroQueueRun?.state != .running,
              let index = scheduledMessages.indices
                .filter({
                    scheduledMessages[$0].status == .pending
                    && scheduledMessages[$0].deliveryMode == .automatic
                    && scheduledMessages[$0].scheduledAt <= .now
                })
                .min(by: { scheduledMessages[$0].scheduledAt < scheduledMessages[$1].scheduledAt })
        else { return }

        let message = scheduledMessages[index]
        guard let account = accounts.first(where: { $0.id == message.accountID }) else {
            scheduledMessages[index].status = .ready
            LocalStore.saveSchedules(scheduledMessages)
            startNextAutomaticScheduleIfNeeded()
            return
        }

        scheduledMessages[index].status = .sending
        activeScheduledSendID = message.id
        LocalStore.saveSchedules(scheduledMessages)
        selectedAccountID = message.accountID
        showingAutomationCenter = false

        let session = WebSessionPool.shared.session(for: account)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.activeScheduledSendID == message.id else { return }
            session.activateChat(named: message.recipientLabel) { [weak self] activated in
                guard let self, self.activeScheduledSendID == message.id else { return }
                guard activated else {
                    self.finishAutomaticSchedule(message.id, sent: false)
                    return
                }
                let queuedCount = session.queueAttachments(paths: message.attachmentPaths, caption: message.body)
                guard queuedCount == message.attachmentPaths.count else {
                    self.finishAutomaticSchedule(message.id, sent: false)
                    return
                }
                session.runPreparedMessageMacro(autoSend: true) { [weak self] success in
                    self?.finishAutomaticSchedule(message.id, sent: success)
                }
            }
        }
    }

    private func finishAutomaticSchedule(_ id: UUID, sent: Bool) {
        guard activeScheduledSendID == id else { return }
        if let index = scheduledMessages.firstIndex(where: { $0.id == id }) {
            scheduledMessages[index].status = sent ? .sent : .ready
            LocalStore.saveSchedules(scheduledMessages)
        }
        activeScheduledSendID = nil
        startNextAutomaticScheduleIfNeeded()
    }

    func prepare(_ message: ScheduledMessage) {
        if let account = accounts.first(where: { $0.id == message.accountID }) {
            let session = WebSessionPool.shared.session(for: account)
            selectedAccountID = message.accountID
            showingAutomationCenter = false
            Task { @MainActor [weak self] in
                // Give SwiftUI time to close the sheet and expose the selected WebView.
                try? await Task.sleep(for: .milliseconds(350))
                session.activateChat(named: message.recipientLabel) { [weak self] activated in
                    guard let self else { return }
                    guard activated else {
                        if let index = self.scheduledMessages.firstIndex(where: { $0.id == message.id }) {
                            self.scheduledMessages[index].status = .ready
                            LocalStore.saveSchedules(self.scheduledMessages)
                        }
                        return
                    }
                    if let index = self.scheduledMessages.firstIndex(where: { $0.id == message.id }) {
                        self.scheduledMessages[index].status = .prepared
                        LocalStore.saveSchedules(self.scheduledMessages)
                    }
                    session.queueAttachments(paths: message.attachmentPaths, caption: message.body)
                    session.runPreparedMessageMacro()
                }
            }
            return
        }
        selectedAccountID = message.accountID
        showingAutomationCenter = false
    }

    func markSent(_ id: UUID) {
        if let index = scheduledMessages.firstIndex(where: { $0.id == id }) {
            scheduledMessages[index].status = .sent
            LocalStore.saveSchedules(scheduledMessages)
        }
    }

    func cancelSchedule(_ id: UUID) {
        guard let index = scheduledMessages.firstIndex(where: { $0.id == id }) else { return }
        scheduledMessages[index].status = .cancelled
        LocalStore.saveSchedules(scheduledMessages)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    func deleteSchedule(_ id: UUID) {
        scheduledMessages.removeAll { $0.id == id }
        LocalStore.saveSchedules(scheduledMessages)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    private func scheduleNotification(for message: ScheduledMessage) {
        guard notificationsEnabled else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            if message.deliveryMode == .automatic {
                content.title = "Envio automático agendado"
                content.body = message.recipientLabel.isEmpty
                    ? "O WhatsCrânio iniciará o envio no chat aberto."
                    : "O envio automático para \(message.recipientLabel) será iniciado."
            } else {
                content.title = "Mensagem agendada pronta"
                content.body = message.recipientLabel.isEmpty
                    ? "Abra o WhatsCrânio para preparar o envio."
                    : "Envio para \(message.recipientLabel) está pronto para confirmação."
            }
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: message.scheduledAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

}
