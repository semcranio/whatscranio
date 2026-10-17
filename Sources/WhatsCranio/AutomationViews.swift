import AppKit
import SwiftUI

struct AutomationCenterView: View {
    @EnvironmentObject private var model: AppModel
    let close: (() -> Void)?
    @State private var tab = 0
    @State private var editingTemplate: QuickMessageTemplate?
    @State private var composingTemplate: QuickMessageTemplate?
    @State private var showingNewTemplate = false
    @State private var showingBlankComposer = false
    @State private var selectedCategory: String?
    @State private var templateSearchText = ""
    @State private var editingMacroQueue: MessageMacroQueue?
    @State private var runningMacroQueue: MessageMacroQueue?
    @State private var showingNewMacroQueue = false
    @State private var macroQueueSearchText = ""

    init(close: (() -> Void)? = nil) {
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Central de mensagens").font(.title2.bold())
                    Text("Modelos, anexos e agendamentos para suas contas")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let close {
                    Button("Fechar", action: close)
                }
                Button { showingBlankComposer = true } label: {
                    Label("Nova mensagem", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Picker("Seção", selection: $tab) {
                Text("Mensagens prontas").tag(0)
                Text("Agendamentos").tag(1)
                Text("Filas de macro").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            if tab == 0 {
                templatesView
            } else if tab == 1 {
                schedulesView
            } else {
                macroQueuesView
            }
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorView(template: template)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingNewTemplate) {
            TemplateEditorView(template: QuickMessageTemplate(title: "", body: ""))
                .environmentObject(model)
        }
        .sheet(item: $composingTemplate) { template in
            ComposeMessageView(template: template, onComplete: close)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingBlankComposer) {
            ComposeMessageView(template: nil, onComplete: close)
                .environmentObject(model)
        }
        .sheet(item: $editingMacroQueue) { queue in
            MacroQueueEditorView(queue: queue)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingNewMacroQueue) {
            MacroQueueEditorView(queue: MessageMacroQueue(name: ""))
                .environmentObject(model)
        }
        .sheet(item: $runningMacroQueue) { queue in
            MacroQueueRunView(queue: queue, onComplete: close)
                .environmentObject(model)
        }
        .onAppear { model.refreshDueSchedules() }
        .onChange(of: model.templates) { _, _ in
            if let selectedCategory, !model.templateCategories.contains(selectedCategory) {
                self.selectedCategory = nil
            }
        }
    }

    private var templatesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(templateCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Buscar mensagens", text: $templateSearchText)
                        .textFieldStyle(.plain)
                    if !templateSearchText.isEmpty {
                        Button { templateSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Limpar busca")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(width: 260)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Picker("Categoria", selection: $selectedCategory) {
                    Text("Todas as categorias").tag(String?.none)
                    ForEach(model.templateCategories, id: \.self) { category in
                        Text(category).tag(Optional(category))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Button { showingNewTemplate = true } label: {
                    Label("Novo modelo", systemImage: "plus")
                }
            }
            .padding(14)

            if model.templates.isEmpty {
                EmptyStateView(title: "Sem modelos", systemImage: "text.badge.plus", description: "Crie mensagens reutilizáveis para responder mais rápido.")
            } else if filteredTemplates.isEmpty {
                EmptyStateView(
                    title: "Nenhuma mensagem encontrada",
                    systemImage: "magnifyingglass",
                    description: "Tente outras palavras ou escolha outra categoria."
                )
            } else {
                List {
                    ForEach(filteredTemplates) { template in
                        TemplateRow(template: template) {
                            composingTemplate = template
                        } edit: {
                            editingTemplate = template
                        } delete: {
                            model.deleteTemplate(template)
                        }
                    }
                }
            }
        }
    }

    private var filteredTemplates: [QuickMessageTemplate] {
        model.templates
            .filter { selectedCategory == nil || $0.categoryLabel == selectedCategory }
            .filter { template in
                matchesSearch(
                    templateSearchText,
                    fields: [template.title, template.body, template.categoryLabel]
                        + template.attachmentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                )
            }
            .sorted {
                let categoryOrder = $0.categoryLabel.localizedCaseInsensitiveCompare($1.categoryLabel)
                if categoryOrder == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return categoryOrder == .orderedAscending
            }
    }

    private var templateCountLabel: String {
        guard selectedCategory != nil || !templateSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(model.templates.count) modelo(s)"
        }
        return "\(filteredTemplates.count) de \(model.templates.count) modelo(s)"
    }

    private var schedulesView: some View {
        Group {
            if model.scheduledMessages.isEmpty {
                EmptyStateView(title: "Sem agendamentos", systemImage: "calendar.badge.clock", description: "Agende uma mensagem para receber o lembrete e prepará-la na conta correta.")
            } else {
                List {
                    ForEach(model.scheduledMessages.sorted(by: { $0.scheduledAt > $1.scheduledAt })) { message in
                        ScheduleRow(message: message)
                    }
                }
            }
        }
    }

    private var macroQueuesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(macroQueueCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Buscar filas ou mensagens", text: $macroQueueSearchText)
                        .textFieldStyle(.plain)
                    if !macroQueueSearchText.isEmpty {
                        Button { macroQueueSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Limpar busca")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(width: 280)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Spacer()
                Button { showingNewMacroQueue = true } label: {
                    Label("Nova fila", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
            .padding(14)

            if model.macroQueues.isEmpty {
                EmptyStateView(
                    title: "Sem filas de macro",
                    systemImage: "square.stack.3d.up",
                    description: "Crie uma sequência usando as mensagens prontas já cadastradas."
                )
            } else if filteredMacroQueues.isEmpty {
                EmptyStateView(
                    title: "Nenhuma fila encontrada",
                    systemImage: "magnifyingglass",
                    description: "Busque pelo nome da fila, mensagem, categoria ou trecho do texto."
                )
            } else {
                List {
                    ForEach(filteredMacroQueues) { queue in
                        MacroQueueRow(queue: queue) {
                            runningMacroQueue = queue
                        } edit: {
                            editingMacroQueue = queue
                        } delete: {
                            model.deleteMacroQueue(queue)
                        }
                    }
                }
            }
        }
    }

    private var filteredMacroQueues: [MessageMacroQueue] {
        model.macroQueues
            .filter { queue in
                let templates = model.templates(for: queue)
                let fields = [queue.name] + templates.flatMap { template in
                    [template.title, template.body, template.categoryLabel]
                        + template.attachmentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                }
                return matchesSearch(macroQueueSearchText, fields: fields)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var macroQueueCountLabel: String {
        guard !macroQueueSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(model.macroQueues.count) fila(s)"
        }
        return "\(filteredMacroQueues.count) de \(model.macroQueues.count) fila(s)"
    }

    private func matchesSearch(_ query: String, fields: [String]) -> Bool {
        let tokens = normalizedSearchText(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        let searchableText = normalizedSearchText(fields.joined(separator: " "))
        return tokens.allSatisfy(searchableText.contains)
    }

    private func normalizedSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct MacroQueueRow: View {
    @EnvironmentObject private var model: AppModel
    let queue: MessageMacroQueue
    let run: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(queue.name).font(.headline)
                Text(summary)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Text("Intervalo de \(queue.intervalSeconds.formatted()) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Executar", action: run)
                .disabled(model.templates(for: queue).count != queue.templateIDs.count || queue.templateIDs.isEmpty)
            Menu {
                Button("Editar", action: edit)
                Button("Excluir", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 6)
    }

    private var summary: String {
        let templates = model.templates(for: queue)
        if templates.isEmpty { return "Nenhuma mensagem adicionada" }
        return templates.map(\.title).joined(separator: " → ")
    }
}

struct MacroQueueEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var value: MessageMacroQueue
    @State private var templateToAdd: UUID?

    init(queue: MessageMacroQueue) {
        _value = State(initialValue: queue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(value.name.isEmpty ? "Nova fila de macro" : "Editar fila de macro")
                .font(.title2.bold())
            TextField("Nome da fila", text: $value.name)

            HStack {
                Picker("Mensagem pronta", selection: $templateToAdd) {
                    Text("Escolha uma mensagem").tag(UUID?.none)
                    ForEach(model.templates) { template in
                        Text("\(template.categoryLabel) — \(template.title)").tag(Optional(template.id))
                    }
                }
                Button("Adicionar") {
                    guard let templateToAdd else { return }
                    value.templateIDs.append(templateToAdd)
                    self.templateToAdd = nil
                }
                .disabled(templateToAdd == nil)
            }

            if value.templateIDs.isEmpty {
                Text("Adicione as mensagens na ordem em que devem ser enviadas.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(value.templateIDs.enumerated()), id: \.offset) { index, templateID in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .frame(width: 24, height: 24)
                                .background(Color.accentColor.opacity(0.15), in: Circle())
                            VStack(alignment: .leading) {
                                Text(template(templateID)?.title ?? "Mensagem removida")
                                if let template = template(templateID) {
                                    Text(template.attachmentPaths.isEmpty ? "Somente texto" : "\(template.attachmentPaths.count) anexo(s)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0)
                                .buttonStyle(.borderless)
                            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == value.templateIDs.count - 1)
                                .buttonStyle(.borderless)
                            Button(role: .destructive) { value.templateIDs.remove(at: index) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            HStack {
                Stepper(value: $value.intervalSeconds, in: 0.5...30, step: 0.5) {
                    Text("Intervalo entre envios: \(value.intervalSeconds.formatted()) s")
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Salvar") {
                    model.saveMacroQueue(value)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.templateIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }

    private func template(_ id: UUID) -> QuickMessageTemplate? {
        model.templates.first(where: { $0.id == id })
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard value.templateIDs.indices.contains(index), value.templateIDs.indices.contains(destination) else { return }
        value.templateIDs.swapAt(index, destination)
    }
}

struct MacroQueueRunView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = UUID()
    @State private var recipientLabel = ""
    @State private var isResolvingRecipient = false
    let queue: MessageMacroQueue
    let onComplete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Executar fila").font(.title2.bold())
            Text(queue.name).font(.headline)
            Picker("Conta", selection: $accountID) {
                ForEach(model.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            TextField("Contato ou conversa de destino", text: $recipientLabel)
            HStack(spacing: 6) {
                if isResolvingRecipient { ProgressView().controlSize(.small) }
                Text("Preenchido com o chat aberto nessa conta. Altere somente se quiser enviar para outro contato.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            List {
                ForEach(Array(model.templates(for: queue).enumerated()), id: \.element.id) { index, template in
                    HStack {
                        Text("\(index + 1).")
                        VStack(alignment: .leading) {
                            Text(template.title)
                            Text(template.attachmentPaths.isEmpty ? "Somente texto" : "\(template.attachmentPaths.count) anexo(s)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Ao iniciar, o WhatsCrânio abrirá “\(recipientLabel.isEmpty ? "destino não informado" : recipientLabel)” e enviará automaticamente todas as mensagens na ordem acima. Se o contato não puder ser confirmado, nada será enviado.")
                .font(.callout)
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Iniciar e enviar") {
                    model.runMacroQueue(queue, accountID: accountID, recipientLabel: recipientLabel)
                    dismiss()
                    if let onComplete { DispatchQueue.main.async { onComplete() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !model.accounts.contains(where: { $0.id == accountID })
                    || model.activeMacroQueueRun != nil
                    || model.activeScheduledSendID != nil
                )
            }
        }
        .padding(20)
        .frame(width: 580, height: 600)
        .onAppear {
            if !model.accounts.contains(where: { $0.id == accountID }) {
                accountID = model.selectedAccountID
            }
            loadActiveRecipient(for: accountID)
        }
        .onChange(of: accountID) { _, newAccountID in
            recipientLabel = ""
            loadActiveRecipient(for: newAccountID)
        }
    }

    private func loadActiveRecipient(for accountID: UUID) {
        guard let account = model.accounts.first(where: { $0.id == accountID }) else { return }
        isResolvingRecipient = true
        WebSessionPool.shared.session(for: account).captureActiveChat { label in
            guard self.accountID == accountID else { return }
            isResolvingRecipient = false
            if recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recipientLabel = label ?? ""
            }
        }
    }
}

struct TemplateRow: View {
    let template: QuickMessageTemplate
    let use: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.title).font(.headline).lineLimit(1)
                Text(template.body).lineLimit(2).foregroundStyle(.secondary)
                if !template.attachmentPaths.isEmpty {
                    Label("\(template.attachmentPaths.count) anexo(s)", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(template.categoryLabel)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            Button("Usar", action: use)
            Menu {
                Button("Editar", action: edit)
                Button("Excluir", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 6)
    }
}

struct TemplateEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var value: QuickMessageTemplate

    init(template: QuickMessageTemplate) {
        _value = State(initialValue: template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(value.title.isEmpty ? "Novo modelo" : "Editar modelo").font(.title2.bold())
            TextField("Nome do modelo", text: $value.title)
            HStack {
                TextField("Categoria", text: $value.category)
                if model.templateCategories.contains(where: { $0 != "Sem categoria" }) {
                    Menu("Categorias existentes") {
                        ForEach(model.templateCategories.filter { $0 != "Sem categoria" }, id: \.self) { category in
                            Button(category) { value.category = category }
                        }
                    }
                }
            }
            TextEditor(text: $value.body)
                .font(.body)
                .frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            AttachmentList(paths: $value.attachmentPaths)
            HStack {
                Button("Adicionar anexos") { chooseAttachments(into: &value.attachmentPaths) }
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Salvar") {
                    model.saveTemplate(value)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 470)
    }
}

struct ComposeMessageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID
    @State private var recipientLabel = ""
    @State private var messageBody: String
    @State private var attachmentPaths: [String]
    @State private var shouldSchedule = false
    @State private var scheduledAt = Date().addingTimeInterval(3600)
    @State private var deliveryMode: ScheduledDeliveryMode = .confirmBeforeSending
    @State private var isResolvingRecipient = false
    let onComplete: (() -> Void)?

    init(template: QuickMessageTemplate?, onComplete: (() -> Void)? = nil) {
        _accountID = State(initialValue: UUID())
        _messageBody = State(initialValue: template?.body ?? "")
        _attachmentPaths = State(initialValue: template?.attachmentPaths ?? [])
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preparar mensagem").font(.title2.bold())

            Picker("Conta", selection: $accountID) {
                ForEach(model.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            TextField("Contato ou conversa de destino", text: $recipientLabel)
            HStack(spacing: 6) {
                if isResolvingRecipient { ProgressView().controlSize(.small) }
                Text("O chat aberto foi preenchido automaticamente. Você pode alterar o destino aqui.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            TextEditor(text: $messageBody)
                .frame(minHeight: 125)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            AttachmentList(paths: $attachmentPaths)
            Button("Adicionar anexos") { chooseAttachments(into: &attachmentPaths) }

            Toggle("Agendar mensagem", isOn: $shouldSchedule)
            if shouldSchedule {
                DatePicker("Data e hora", selection: $scheduledAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Picker("Ao chegar o horário", selection: $deliveryMode) {
                    ForEach(ScheduledDeliveryMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(helperText)
                .font(.caption)
                .foregroundStyle(shouldSchedule && deliveryMode == .automatic ? .orange : .secondary)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button(shouldSchedule ? "Agendar" : "Preparar no chat") {
                    if shouldSchedule {
                        model.scheduleMessage(
                            accountID: accountID,
                            recipientLabel: recipientLabel,
                            body: messageBody,
                            attachmentPaths: attachmentPaths,
                            date: scheduledAt,
                            deliveryMode: deliveryMode
                        )
                    } else {
                        model.prepare(ScheduledMessage(accountID: accountID, recipientLabel: recipientLabel, body: messageBody, attachmentPaths: attachmentPaths, scheduledAt: .now, status: .ready))
                    }
                    dismiss()
                    if let onComplete {
                        DispatchQueue.main.async { onComplete() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !model.accounts.contains(where: { $0.id == accountID })
                )
            }
        }
        .padding(20)
        .frame(width: 560, height: 610)
        .onAppear {
            if !model.accounts.contains(where: { $0.id == accountID }) {
                accountID = model.accounts.first?.id ?? UUID()
            }
            loadActiveRecipient(for: accountID)
        }
        .onChange(of: accountID) { _, newAccountID in
            recipientLabel = ""
            loadActiveRecipient(for: newAccountID)
        }
    }

    private func loadActiveRecipient(for accountID: UUID) {
        guard let account = model.accounts.first(where: { $0.id == accountID }) else { return }
        isResolvingRecipient = true
        WebSessionPool.shared.session(for: account).captureActiveChat { label in
            guard self.accountID == accountID else { return }
            isResolvingRecipient = false
            if recipientLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recipientLabel = label ?? ""
            }
        }
    }

    private var helperText: String {
        if shouldSchedule && deliveryMode == .automatic {
            return "No horário definido, o WhatsCrânio abrirá o contato indicado acima e enviará sem confirmação. O app precisa estar em execução e a conta conectada. Se o destino não puder ser confirmado, nada será enviado."
        }
        if shouldSchedule {
            return "No horário definido, a mensagem ficará pronta. Você poderá revisar o chat, os anexos e a legenda antes de confirmar o envio."
        }
        return "No envio imediato, o WhatsCrânio usa o chat que já está aberto, escolhe automaticamente Foto/Vídeo ou Documento, anexa os arquivos e preenche a legenda. Você apenas revisa e confirma o envio."
    }
}

struct AttachmentList: View {
    @Binding var paths: [String]

    var body: some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Image(systemName: "paperclip")
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        Spacer()
                        Button { paths.removeAll { $0 == path } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
            .padding(9)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ScheduleRow: View {
    @EnvironmentObject private var model: AppModel
    let message: ScheduledMessage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3).foregroundStyle(statusColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.recipientLabel.isEmpty ? "Destinatário a escolher" : message.recipientLabel).font(.headline)
                Text(message.body).lineLimit(2).foregroundStyle(.secondary)
                HStack {
                    Text(accountName)
                    Text("•")
                    Text(message.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                    if !message.attachmentPaths.isEmpty {
                        Text("• \(message.attachmentPaths.count) anexo(s)")
                    }
                    Text("• \(message.deliveryMode.label)")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(message.status.label)
                .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                .background(statusColor.opacity(0.14), in: Capsule())
            if [.pending, .ready, .prepared].contains(message.status) {
                Button(message.deliveryMode == .automatic ? "Preparar manualmente" : "Preparar") { model.prepare(message) }
                Button("Cancelar") { model.cancelSchedule(message.id) }
            }
            Menu {
                Button("Marcar como enviada") { model.markSent(message.id) }
                Button("Excluir", role: .destructive) { model.deleteSchedule(message.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .disabled(message.status == .sending)
        }
        .padding(.vertical, 6)
    }

    private var accountName: String {
        model.accounts.first(where: { $0.id == message.accountID })?.name ?? "Conta removida"
    }

    private var statusIcon: String {
        switch message.status {
        case .pending: "clock"
        case .ready: "bell.badge.fill"
        case .sending: "paperplane.fill"
        case .prepared: "doc.on.clipboard.fill"
        case .sent: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch message.status {
        case .pending: .orange
        case .ready: .blue
        case .sending: .blue
        case .prepared: .purple
        case .sent: .green
        case .cancelled: .secondary
        }
    }
}

@MainActor
private func chooseAttachments(into paths: inout [String]) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if panel.runModal() == .OK {
        let additions = panel.urls.map(\.path)
        paths = Array(Set(paths + additions)).sorted()
    }
}
