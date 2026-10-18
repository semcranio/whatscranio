import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    private let scheduler = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private let lockScheduler = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            IntegratedWebAccountsView()
                .background(Color(nsColor: .windowBackgroundColor))
                .blur(radius: model.isLocked ? 18 : 0)
                .allowsHitTesting(!model.isLocked)

            if let run = model.activeMacroQueueRun {
                VStack {
                    HStack {
                        Spacer()
                        MacroQueueProgressCard(run: run)
                    }
                    Spacer()
                }
                .padding(18)
            }

            if model.isLocked {
                ZStack {
                    Color.black.opacity(0.42).ignoresSafeArea()
                    LockView()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isLocked)
        .onAppear {
            DesktopNotificationService.configure()
            if model.messageNotificationsEnabled {
                DesktopNotificationService.requestAuthorization()
            }
            model.startActivityMonitoring()
            model.startDeepLinkHandling()
            model.recordUserActivity()
            synchronizeWebSessions()
            model.refreshDueSchedules()
        }
        .onDisappear { model.stopActivityMonitoring() }
        .onChange(of: model.accounts) { _, _ in synchronizeWebSessions() }
        .onChange(of: model.selectedAccountID) { _, _ in synchronizeWebSessions() }
        .onReceive(scheduler) { _ in model.refreshDueSchedules() }
        .onReceive(lockScheduler) { date in model.evaluateAutoLock(at: date) }
        .onReceive(NotificationCenter.default.publisher(for: .whatscranioOpenNotificationAccount)) { notification in
            guard let accountID = notification.object as? UUID else { return }
            model.openAccountFromNotification(accountID)
        }
        .sheet(isPresented: $model.showingAddAccount) {
            AddAccountView().environmentObject(model)
        }
        .sheet(isPresented: $model.showingAutomationCenter) {
            AutomationCenterView { model.showingAutomationCenter = false }
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 620)
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 620)
        }
        .sheet(isPresented: $model.showingDonation) {
            DonationView()
                .environmentObject(model)
                .frame(width: 540, height: 680)
        }
        .sheet(item: $model.pendingWhatsAppLink) { link in
            WhatsAppLinkAccountPicker(link: link)
                .environmentObject(model)
        }
        .alert(
            "Não foi possível abrir o link",
            isPresented: Binding(
                get: { model.deepLinkErrorMessage != nil },
                set: { if !$0 { model.deepLinkErrorMessage = nil } }
            )
        ) {
            Button("OK") { model.deepLinkErrorMessage = nil }
        } message: {
            Text(model.deepLinkErrorMessage ?? "")
        }
    }

    private func synchronizeWebSessions() {
        let appModel = model
        WebSessionPool.shared.configureNavigation(
            accounts: model.accounts,
            selectedAccountID: model.selectedAccountID
        ) { [weak appModel] action in
            guard let appModel else { return }
            switch action {
            case .selectAccount(let accountID):
                guard appModel.accounts.contains(where: { $0.id == accountID }) else { return }
                appModel.selectedAccountID = accountID
            case .unreadStateChanged(let accountID, let total):
                appModel.updateUnreadMessages(total, for: accountID)
            case .incomingMessage(let accountID, let sender, let preview, let conversationID):
                appModel.handleIncomingMessage(
                    accountID: accountID,
                    sender: sender,
                    preview: preview,
                    conversationID: conversationID
                )
            case .addAccount:
                appModel.showingAddAccount = true
            case .openAutomation:
                appModel.showingAutomationCenter = true
            case .openSettings:
                appModel.showingSettings = true
            case .openDonation:
                appModel.showingDonation = true
            case .lock:
                appModel.lockNow()
            }
        }
        WebSessionPool.shared.prewarm(accounts: model.accounts)
    }
}

struct WhatsAppLinkAccountPicker: View {
    @EnvironmentObject private var model: AppModel
    let link: WhatsAppDeepLink
    @State private var rememberAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "message.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Abrir conversa no WhatsApp")
                        .font(.title2.bold())
                    Text("Escolha em qual conta este link será aberto.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if let phone = link.phone {
                    Label(phone, systemImage: "phone")
                        .font(.headline)
                        .textSelection(.enabled)
                }
                if let text = link.text, !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                }
            }

            VStack(spacing: 8) {
                ForEach(model.accounts) { account in
                    Button {
                        model.openPendingWhatsAppLink(
                            in: account.id,
                            rememberAccount: rememberAccount
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(initials: initials(for: account), tint: account.tint, size: 34)
                            Text(account.name)
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
                }
            }

            Toggle("Usar sempre a conta escolhida para links do WhatsApp", isOn: $rememberAccount)

            HStack {
                Spacer()
                Button("Cancelar") { model.cancelPendingWhatsAppLink() }
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private func initials(for account: WebAccount) -> String {
        account.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct MacroQueueProgressCard: View {
    @EnvironmentObject private var model: AppModel
    let run: MacroQueueRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(run.queueName).font(.headline)
                Spacer()
            }
            Label(run.recipientLabel, systemImage: "person.crop.circle")
                .font(.caption.bold())
                .lineLimit(1)
            if run.state == .running {
                ProgressView(value: Double(run.currentIndex), total: Double(max(run.total, 1)))
                Text("\(run.currentTitle) — \(run.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Interromper") { model.cancelMacroQueue() }
                }
            } else {
                Text(run.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Fechar") { model.dismissMacroQueueRun() }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }

    private var icon: String {
        switch run.state {
        case .running: "paperplane.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch run.state {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

struct IntegratedWebAccountsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            ForEach(model.accounts) { account in
                WhatsAppWebContainer(account: account)
                    .opacity(model.selectedAccountID == account.id ? 1 : 0)
                    .allowsHitTesting(model.selectedAccountID == account.id)
                    .accessibilityHidden(model.selectedAccountID != account.id)
            }
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adicionar conta").font(.title2.bold())
            Text("Cada conta usa um armazenamento WebKit persistente e isolado. Você fará o login pelo QR Code do próprio WhatsApp Web.")
                .foregroundStyle(.secondary)
            TextField("Nome da conta", text: $name)
                .onSubmit { add() }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Adicionar", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 210)
    }

    private func add() {
        model.addAccount(name: name)
        dismiss()
    }
}

struct Avatar: View {
    let initials: String
    let tint: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: tint).gradient)
            Text(initials).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct LockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.accentColor)
            Text("WhatsCrânio bloqueado").font(.title2.bold())
            Text("Digite sua senha para voltar às conversas.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField("Senha", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit(unlock)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button("Desbloquear", action: unlock)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(password.isEmpty)
        }
        .padding(34)
        .frame(width: 370)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 28)
        .onAppear { passwordFocused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        if model.unlock(with: password) {
            password = ""
            errorMessage = nil
        } else {
            password = ""
            errorMessage = "Senha incorreta."
            passwordFocused = true
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var accountBeingEdited: WebAccount?
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var passwordConfirmation = ""
    @State private var lockFeedback: String?
    @State private var lockFeedbackIsError = false

    var body: some View {
        Form {
            Section("Geral") {
                Toggle("Notificar novas mensagens do WhatsApp", isOn: $model.messageNotificationsEnabled)
                Toggle("Notificar mensagens agendadas", isOn: $model.notificationsEnabled)
                Text("O ícone do WhatsCrânio na barra de menus mostra o total de mensagens não lidas de todas as contas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Bloqueio") {
                if model.hasLockPassword {
                    Label("Senha de bloqueio configurada", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    SecureField("Senha atual", text: $currentPassword)
                    SecureField("Nova senha", text: $newPassword)
                    SecureField("Confirmar nova senha", text: $passwordConfirmation)
                    HStack {
                        Button("Alterar senha", action: changePassword)
                            .disabled(currentPassword.isEmpty || newPassword.isEmpty || passwordConfirmation.isEmpty)
                        Button("Remover senha", role: .destructive, action: removePassword)
                            .disabled(currentPassword.isEmpty)
                    }
                } else {
                    Text("Crie uma senha para habilitar o bloqueio manual e automático.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SecureField("Nova senha", text: $newPassword)
                    SecureField("Confirmar senha", text: $passwordConfirmation)
                    Button("Definir senha", action: setPassword)
                        .disabled(newPassword.isEmpty || passwordConfirmation.isEmpty)
                }

                Toggle("Bloqueio automático", isOn: $model.autoLockEnabled)
                    .disabled(!model.hasLockPassword)
                Stepper(value: $model.autoLockMinutes, in: 1...120) {
                    Text("Bloquear após \(model.autoLockMinutes) \(model.autoLockMinutes == 1 ? "minuto" : "minutos")")
                }
                .disabled(!model.hasLockPassword || !model.autoLockEnabled)

                Button("Bloquear agora") {
                    model.lockNow()
                }
                .disabled(!model.hasLockPassword)

                if let lockFeedback {
                    Text(lockFeedback)
                        .font(.callout)
                        .foregroundStyle(lockFeedbackIsError ? .red : .green)
                }
            }
            Section("Contas") {
                ForEach(model.accounts) { account in
                    HStack {
                        Avatar(initials: initials(for: account), tint: account.tint, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            Text("Cor #\(account.tint.uppercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            accountBeingEdited = account
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .help("Editar nome e cor desta conta")
                        if model.accounts.count > 1 {
                            Button("Remover", role: .destructive) { model.removeAccount(account) }
                                .help("Remover esta conta e sua sessão local")
                        }
                    }
                }
                Button("Adicionar conta") {
                    model.showingSettings = false
                    model.showingAddAccount = true
                }
            }
            Section("Links do WhatsApp") {
                HStack {
                    Label(
                        model.isDefaultWhatsAppLinkHandler
                            ? "WhatsCrânio é o aplicativo padrão"
                            : "Outro aplicativo abre os links atualmente",
                        systemImage: model.isDefaultWhatsAppLinkHandler
                            ? "checkmark.circle.fill"
                            : "link.badge.plus"
                    )
                    .foregroundStyle(model.isDefaultWhatsAppLinkHandler ? .green : .secondary)
                    Spacer()
                    if !model.isDefaultWhatsAppLinkHandler {
                        Button("Usar WhatsCrânio") {
                            model.makeDefaultWhatsAppLinkHandler()
                        }
                    }
                }
                if let account = model.preferredDeepLinkAccount {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Conta usada automaticamente")
                                .font(.headline)
                            Text(account.name)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Perguntar sempre") {
                            model.clearPreferredDeepLinkAccount()
                        }
                    }
                } else {
                    Text("Quando um link do WhatsApp for aberto e houver mais de uma conta, o WhatsCrânio perguntará qual conta deve receber a conversa.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let feedback = model.defaultLinkHandlerFeedback {
                    Text(feedback)
                        .font(.callout)
                        .foregroundStyle(model.isDefaultWhatsAppLinkHandler ? .green : .red)
                }
            }
            Section("Notificações") {
                Text("O WhatsCrânio observa novas mensagens nas contas carregadas e usa as notificações nativas do macOS. Ao clicar em um alerta, a conta correspondente é aberta. O contador também aparece na barra de menus e no ícone do Dock.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Privacidade") {
                Text("Cada conta usa armazenamento WebKit persistente separado. O app mantém todas as contas carregadas enquanto está aberto e aguarda a gravação do WebKit ao encerrar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $accountBeingEdited) { account in
            EditAccountView(account: account)
                .environmentObject(model)
        }
    }

    private func setPassword() {
        present(model.setInitialLockPassword(newPassword, confirmation: passwordConfirmation))
    }

    private func changePassword() {
        present(model.changeLockPassword(
            current: currentPassword,
            newPassword: newPassword,
            confirmation: passwordConfirmation
        ))
    }

    private func removePassword() {
        present(model.removeLockPassword(current: currentPassword), removed: true)
    }

    private func present(_ result: LockPasswordChangeResult, removed: Bool = false) {
        lockFeedbackIsError = result != .success
        switch result {
        case .success:
            lockFeedback = removed ? "Senha removida e bloqueio automático desativado." : "Senha salva com segurança no Chaveiro do macOS."
            currentPassword = ""
            newPassword = ""
            passwordConfirmation = ""
        case .passwordTooShort:
            lockFeedback = "A senha precisa ter pelo menos 4 caracteres."
        case .passwordsDoNotMatch:
            lockFeedback = "A confirmação não corresponde à nova senha."
        case .currentPasswordIncorrect:
            lockFeedback = "A senha atual está incorreta."
        case .storageFailure:
            lockFeedback = "Não foi possível acessar o Chaveiro do macOS."
        }
    }

    private func initials(for account: WebAccount) -> String {
        account.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct EditAccountView: View {
    private static let availableTints = [
        "1DAA82", "5B8DEF", "E58A3B", "8F6AD7", "D45D79",
        "21A7D9", "D3A72E", "C05A9D", "637080", "CF4B3E"
    ]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let account: WebAccount
    @State private var name: String
    @State private var selectedTint: String

    init(account: WebAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _selectedTint = State(initialValue: account.tint.uppercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Avatar(initials: initials, tint: selectedTint, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Editar conta")
                        .font(.title2.bold())
                    Text("A sessão do WhatsApp será preservada.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Nome")
                    .font(.headline)
                TextField("Nome da conta", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Cor de fundo")
                    .font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 10), count: 5), spacing: 10) {
                    ForEach(Self.availableTints, id: \.self) { tint in
                        Button {
                            selectedTint = tint
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: tint).gradient)
                                    .frame(width: 30, height: 30)
                                if selectedTint == tint {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .shadow(radius: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Usar a cor #\(tint)")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    if model.updateAccount(account, name: name, tint: selectedTint) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 390)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x1DAA82
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
