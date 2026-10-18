import SwiftUI

@main
struct WhatsCranioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WhatsCrânio") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("WhatsCrânio") {
                Button("Mensagens e agenda") { model.showingAutomationCenter = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                if let first = model.accounts.first {
                    Button("Abrir conta principal") { model.selectedAccountID = first.id }
                        .keyboardShortcut("1")
                }
                Divider()
                Button("Bloquear") { model.lockNow() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 620)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationReplyPending = false
    private var terminationDidReply = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableSuddenTermination()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { WhatsAppDeepLinkRouter.shared.receive($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        terminationDidReply = false

        Task { @MainActor [weak self] in
            await WebSessionPool.shared.flushPersistentData()
            self?.finishTermination()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !terminationDidReply else { return }
        terminationDidReply = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    @objc
    private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: value)
        else { return }
        WhatsAppDeepLinkRouter.shared.receive(url)
    }
}
