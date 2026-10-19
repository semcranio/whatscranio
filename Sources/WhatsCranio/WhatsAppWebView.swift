import AppKit
import SwiftUI
import WebKit

enum WebAppAction {
    case selectAccount(UUID)
    case unreadStateChanged(accountID: UUID, total: Int)
    case incomingMessage(accountID: UUID, sender: String, preview: String, conversationID: String)
    case addAccount
    case openAutomation
    case openSettings
    case openDonation
    case lock
}

enum WebLinkRouting {
    private static let externalSchemes = Set(["http", "https", "mailto", "tel"])

    static func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), externalSchemes.contains(scheme) else { return false }
        if scheme == "http" || scheme == "https" {
            return url.host?.lowercased() != "web.whatsapp.com"
        }
        return true
    }
}

@MainActor
final class WebActionBridge: NSObject, WKScriptMessageHandler {
    var handler: ((WebAppAction) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], let action = payload["action"] as? String else { return }
        switch action {
        case "selectAccount":
            guard let value = payload["accountID"] as? String, let accountID = UUID(uuidString: value) else { return }
            handler?(.selectAccount(accountID))
        case "unreadStateChanged":
            guard let value = payload["accountID"] as? String,
                  let accountID = UUID(uuidString: value),
                  let total = payload["total"] as? Int else { return }
            handler?(.unreadStateChanged(accountID: accountID, total: total))
        case "incomingMessage":
            guard let value = payload["accountID"] as? String,
                  let accountID = UUID(uuidString: value),
                  let sender = payload["sender"] as? String,
                  let preview = payload["preview"] as? String,
                  let conversationID = payload["conversationID"] as? String else { return }
            handler?(.incomingMessage(
                accountID: accountID,
                sender: sender,
                preview: preview,
                conversationID: conversationID
            ))
        case "addAccount": handler?(.addAccount)
        case "openAutomation": handler?(.openAutomation)
        case "openSettings": handler?(.openSettings)
        case "openDonation": handler?(.openDonation)
        case "lock": handler?(.lock)
        default: break
        }
    }
}

@MainActor
final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private enum AttachmentPickerKind: String {
        case media
        case document
    }

    private enum PreparedMessageKind {
        case text
        case attachment
    }

    let webView: WKWebView
    let actionBridge: WebActionBridge
    private var queuedAttachmentURLs: [URL] = []
    private var queuedAttachmentCaption: String?
    private var preparedMessageMacroID: UUID?
    private var preparedMessageAutoSend = false
    private var preparedMessageKind: PreparedMessageKind = .text
    private var preparedMessageCompletion: ((Bool) -> Void)?
    private var preparedSendClickIssued = false
    private var activeQueueRunID: UUID?
    private var activeQueueCompletion: ((MessageQueueResult) -> Void)?
    private var integratedNavigationScript: String?
    private var activeDeepLinkID: UUID?

    private static var safariApplicationName: String {
        let safariVersion = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "18.0"
        return "Version/\(safariVersion) Safari/605.1.15"
    }

    private static let dismissUnsupportedWebPromptsScript = """
    (() => {
      if (location.origin !== "https://web.whatsapp.com") return;
      const noticePatterns = [
        /(?:notifica(?:ç|c)[õo]es de mensagens e liga(?:ç|c)[õo]es est(?:ã|a)o desativadas|notifications? for messages and calls (?:are )?(?:turned off|disabled))/i,
        /(?:ativ(?:e|ar) a sincroniza(?:ç|c)[ãa]o em segundo plano|turn on background sync|enable background sync)/i
      ];
      const activationPattern = /(?:^|\\s)(?:ativar|turn on|enable)(?:\\s|$)/i;
      const closePattern = /(?:^|\\s)(?:fechar|close|dismiss)(?:\\s|$)/i;
      const matchesUnsupportedNotice = (value) => noticePatterns.some((pattern) => pattern.test(value || ""));
      const labelFor = (element) => [
        element.getAttribute?.("aria-label"),
        element.getAttribute?.("title"),
        element.textContent
      ].filter(Boolean).join(" ").trim();
      const dismiss = () => {
        const notice = Array.from(document.querySelectorAll("div, span, p"))
          .find((element) => matchesUnsupportedNotice(element.textContent));
        if (!notice) return false;
        let container = notice;
        for (let depth = 0; container && depth < 15; depth += 1, container = container.parentElement) {
          const buttons = Array.from(container.querySelectorAll("button, [role='button']"));
          const text = labelFor(container);
          const hasActivation = buttons.some((button) => activationPattern.test(labelFor(button)))
            || activationPattern.test(text);
          if (!hasActivation) continue;
          const rect = container.getBoundingClientRect();
          if (rect.height <= 0 || rect.height > 240) continue;
          const close = buttons.find((button) => closePattern.test(labelFor(button)));
          close?.click();
          if (container.isConnected) {
            container.style.setProperty("display", "none", "important");
            container.setAttribute("aria-hidden", "true");
          }
          return true;
        }
        const close = Array.from(document.querySelectorAll("button, [role='button']"))
          .find((button) => closePattern.test(labelFor(button)));
        if (close) {
          close.click();
          const banner = close.closest("div");
          if (banner && matchesUnsupportedNotice(banner.textContent)) {
            banner.style.setProperty("display", "none", "important");
            banner.setAttribute("aria-hidden", "true");
          }
          return true;
        }
        return false;
      };
      window.__whatscranioDismissUnsupportedWebPrompts = dismiss;
      dismiss();
      const observer = new MutationObserver(() => dismiss());
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["aria-label", "title"]
      });
    })();
    """

    private static func messageNotificationScript(accountID: UUID) -> String {
        """
        (() => {
          if (location.origin !== "https://web.whatsapp.com" || window.__whatscranioMessageObserver) return;
          const accountID = "\(accountID.uuidString)";
          const state = new Map();
          let initialized = false;
          let lastTotal = -1;
          let scanTimer = null;
          const clean = (value) => (value || "").replace(/\\s+/g, " ").trim();
          const unreadPattern = /(?:^|\\s)(\\d+)?\\s*(?:mensagens? não lidas?|unread messages?)(?:$|\\s)/i;
          const visible = (element) => {
            const rect = element?.getBoundingClientRect?.();
            return !!rect && rect.width > 0 && rect.height > 0;
          };
          const unreadCount = (row) => {
            const candidates = [row, ...row.querySelectorAll('[aria-label], [title]')];
            for (const element of candidates) {
              const label = clean([
                element.getAttribute?.("aria-label"),
                element.getAttribute?.("title"),
                element.textContent
              ].filter(Boolean).join(" "));
              const match = unreadPattern.exec(label);
              if (match) return Math.max(1, Number(match[1] || 1));
            }
            return 0;
          };
          const rowContent = (row) => {
            const lines = (row.innerText || "").split(/\\n+/).map(clean).filter(Boolean);
            const titled = Array.from(row.querySelectorAll('[title]'))
              .map((element) => clean(element.getAttribute("title")))
              .filter(Boolean);
            const isMetadata = (value) =>
              !value
              || /^\\d+$/.test(value)
              || /^\\d{1,2}:\\d{2}$/.test(value)
              || unreadPattern.test(value)
              || /^(?:hoje|ontem|today|yesterday|você|you|\\(você\\)|\\(you\\))$/i.test(value);
            const sender = titled.find((value) => !isMetadata(value))
              || lines.find((value) => !isMetadata(value))
              || "WhatsApp";
            const preview = [...lines].reverse().find((value) =>
              value !== sender
              && !isMetadata(value)
            ) || "";
            return { sender, preview };
          };
          const post = (payload) => window.webkit?.messageHandlers?.whatscranio?.postMessage(payload);
          const scan = () => {
            scanTimer = null;
            const pane = document.querySelector("#pane-side");
            const rows = pane ? Array.from(pane.querySelectorAll(
              '[role="listitem"], [role="row"], [data-testid="cell-frame-container"]'
            )).filter(visible) : [];
            for (const row of rows) {
              const unread = unreadCount(row);
              const { sender, preview } = rowContent(row);
              const conversationID = clean(sender).toLocaleLowerCase();
              if (!conversationID) continue;
              const previous = state.get(conversationID);
              if (initialized && unread > 0
                  && (!previous || unread > previous.unread || preview !== previous.preview)) {
                post({ action: "incomingMessage", accountID, sender, preview, conversationID });
              }
              state.set(conversationID, { unread, preview });
            }
            const titleMatch = /^\\((\\d+)\\)/.exec(document.title || "");
            const total = titleMatch
              ? Number(titleMatch[1])
              : Array.from(state.values()).reduce((sum, item) => sum + item.unread, 0);
            if (total !== lastTotal) {
              lastTotal = total;
              post({ action: "unreadStateChanged", accountID, total });
            }
            initialized = true;
          };
          const scheduleScan = () => {
            clearTimeout(scanTimer);
            scanTimer = setTimeout(scan, 350);
          };
          window.__whatscranioMessageObserver = new MutationObserver(scheduleScan);
          window.__whatscranioMessageObserver.observe(document.documentElement, {
            childList: true,
            subtree: true,
            characterData: true,
            attributes: true,
            attributeFilter: ["aria-label", "title"]
          });
          scheduleScan();
        })();
        """
    }

    init(account: WebAccount) {
        let actionBridge = WebActionBridge()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.dataStoreID)
        configuration.applicationNameForUserAgent = Self.safariApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(actionBridge, name: "whatscranio")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.dismissUnsupportedWebPromptsScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.messageNotificationScript(accountID: account.id),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        self.actionBridge = actionBridge
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        loadWhatsAppIfNeeded()
    }

    func loadWhatsAppIfNeeded() {
        guard webView.url == nil, let url = URL(string: "https://web.whatsapp.com") else { return }
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 60))
    }

    func openWhatsAppLink(_ link: WhatsAppDeepLink) {
        activeDeepLinkID = link.id
        guard let phone = link.phone else {
            prepareDeepLinkText(link)
            return
        }
        captureActiveChat { [weak self] label in
            guard let self, self.activeDeepLinkID == link.id else { return }
            if label.map({ WhatsAppPhoneNumber.matches(phone, $0) }) == true {
                self.prepareDeepLinkText(link)
            } else {
                self.performSoftDeepLinkNavigation(link) { [weak self] in
                    self?.waitForSoftDeepLinkTarget(link, phone: phone)
                }
            }
        }
    }

    private func performSoftDeepLinkNavigation(_ link: WhatsAppDeepLink, completion: @escaping () -> Void) {
        guard webView.url?.host == "web.whatsapp.com",
              let urlData = try? JSONSerialization.data(withJSONObject: link.webURL.absoluteString, options: .fragmentsAllowed),
              let urlLiteral = String(data: urlData, encoding: .utf8)
        else {
            completion()
            return
        }

        let script = """
        (() => {
          const destination = new URL(\(urlLiteral));
          const route = destination.pathname + destination.search;
          history.pushState({ whatscranioDeepLink: true }, "", route);
          window.dispatchEvent(new PopStateEvent("popstate", { state: history.state }));
          return location.href;
        })();
        """

        webView.evaluateJavaScript(script) { _, _ in
            Task { @MainActor in completion() }
        }
    }

    private func waitForSoftDeepLinkTarget(_ link: WhatsAppDeepLink, phone: String, attempt: Int = 0) {
        guard activeDeepLinkID == link.id else { return }
        captureActiveChat { [weak self] label in
            guard let self, self.activeDeepLinkID == link.id else { return }
            if label.map({ WhatsAppPhoneNumber.matches(phone, $0) }) == true {
                self.prepareDeepLinkText(link)
            } else if attempt < 20 {
                self.clickVisibleChatRow(matching: phone) { [weak self] in
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        self?.waitForSoftDeepLinkTarget(link, phone: phone, attempt: attempt + 1)
                    }
                }
            } else {
                self.openDeepLinkWithReloadFallback(link, phone: phone)
            }
        }
    }

    private func clickVisibleChatRow(matching phone: String, completion: @escaping () -> Void) {
        guard let phoneData = try? JSONSerialization.data(withJSONObject: phone, options: .fragmentsAllowed),
              let phoneLiteral = String(data: phoneData, encoding: .utf8)
        else {
            completion()
            return
        }
        let script = """
        (() => {
          const target = \(phoneLiteral);
          const clean = (value) => (value || "").replace(/\\s+/g, " ").trim();
          const variants = (value) => {
            const digits = (value || "").replace(/\\D/g, "");
            const result = new Set(digits ? [digits] : []);
            if (digits.startsWith("55") && digits.length === 13 && digits[4] === "9") {
              result.add(digits.slice(0, 4) + digits.slice(5));
            } else if (digits.startsWith("55") && digits.length === 12) {
              result.add(digits.slice(0, 4) + "9" + digits.slice(4));
            }
            return Array.from(result);
          };
          const matches = (value) => variants(value).some((candidate) =>
            candidate.length >= 8 && variants(target).some((expected) =>
              expected.length >= 8 && (candidate.endsWith(expected) || expected.endsWith(candidate))
            )
          );
          const visible = (element) => {
            const rect = element?.getBoundingClientRect?.();
            const style = element ? getComputedStyle(element) : null;
            return !!rect && rect.width > 0 && rect.height > 0 && style?.display !== "none" && style?.visibility !== "hidden";
          };
          const pane = document.querySelector("#pane-side");
          if (!pane) return null;
          const rows = Array.from(pane.querySelectorAll(
            '[role="listitem"], [role="row"], [data-testid="cell-frame-container"]'
          )).filter(visible);
          const row = rows.find((element) => {
            const values = [element.innerText];
            for (const child of [element, ...element.querySelectorAll('[title], [aria-label]')]) {
              values.push(child.getAttribute?.("title"), child.getAttribute?.("aria-label"));
            }
            return values.filter(Boolean).map(clean).some(matches);
          });
          if (!row) return null;
          const clickable = row.closest('[role="listitem"], [role="row"]') || row;
          const rect = clickable.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + Math.min(rect.height / 2, 36) };
        })();
        """
        let webSession = self
        webView.evaluateJavaScript(script) { result, _ in
            Task { @MainActor in
                if let point = result as? [String: Any],
                   let x = point["x"] as? Double,
                   let y = point["y"] as? Double {
                    webSession.performTrustedWebClick(x: x, y: y)
                }
                completion()
            }
        }
    }

    private func openDeepLinkWithReloadFallback(_ link: WhatsAppDeepLink, phone: String) {
        guard activeDeepLinkID == link.id else { return }
        webView.load(URLRequest(
            url: link.webURL,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 60
        ))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.activeDeepLinkID == link.id else { return }
            self.waitForReloadedDeepLinkTarget(link, phone: phone)
        }
    }

    private func waitForReloadedDeepLinkTarget(_ link: WhatsAppDeepLink, phone: String, attempt: Int = 0) {
        guard activeDeepLinkID == link.id else { return }
        captureActiveChat { [weak self] label in
            guard let self, self.activeDeepLinkID == link.id else { return }
            if label.map({ WhatsAppPhoneNumber.matches(phone, $0) }) == true {
                self.prepareDeepLinkText(link)
            } else if attempt < 40 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.waitForReloadedDeepLinkTarget(link, phone: phone, attempt: attempt + 1)
                }
            } else {
                self.activeDeepLinkID = nil
            }
        }
    }

    private func prepareDeepLinkText(_ link: WhatsAppDeepLink) {
        guard activeDeepLinkID == link.id else { return }
        guard let text = link.text, !text.isEmpty else {
            activeDeepLinkID = nil
            return
        }
        queueAttachments(paths: [], caption: text)
        runPreparedMessageMacro { [weak self] _ in
            guard self?.activeDeepLinkID == link.id else { return }
            self?.activeDeepLinkID = nil
        }
    }

    func updateIntegratedNavigation(accounts: [WebAccount], selectedAccountID: UUID) {
        let accountPayload = accounts.map { account in
            [
                "id": account.id.uuidString,
                "name": account.name,
                "initials": account.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased(),
                "tint": account.tint
            ]
        }
        let payload: [String: Any] = [
            "accounts": accountPayload,
            "selectedAccountID": selectedAccountID.uuidString
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }

        let script = """
        (() => {
          if (location.origin !== "https://web.whatsapp.com") return;
          const config = \(json);
          window.__whatscranioConfig = config;

          const post = (action, accountID) => {
            const payload = accountID ? { action, accountID } : { action };
            window.webkit?.messageHandlers?.whatscranio?.postMessage(payload);
          };
          const buttonLabel = (element) => [
            element.getAttribute?.("aria-label"),
            element.getAttribute?.("title"),
            element.textContent
          ].filter(Boolean).join(" ").trim();
          const findChatButton = () => Array.from(document.querySelectorAll('button, [role="button"]'))
            .find((element) => /^(?:conversas|chats)(?:\\s|$)/i.test(buttonLabel(element)));
          const findRail = () => {
            const chatButton = findChatButton();
            if (!chatButton) return null;
            let current = chatButton.parentElement;
            let best = null;
            while (current && current !== document.body) {
              const rect = current.getBoundingClientRect();
              if (rect.left < 120 && rect.width >= 40 && rect.width <= 100 && rect.height > 280) best = current;
              current = current.parentElement;
            }
            return best || chatButton.parentElement;
          };
          const icons = {
            add: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>`,
            automation: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 2 4.5 13h6L9.8 22 19.5 10h-6L13 2Z"/></svg>`,
            settings: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9c.12.6.64 1.02 1.25 1H21a2 2 0 1 1 0 4h-.35c-.61 0-1.13.42-1.25 1Z"/></svg>`,
            donation: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8l1.1 1.1L12 21l7.8-7.5 1.1-1.1a5.5 5.5 0 0 0-.1-7.8Z"/><path d="M8.5 11.5h7M12 8v7"/></svg>`,
            lock: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>`
          };

          const updateFallbackContrast = (rail) => {
            const channels = getComputedStyle(rail).backgroundColor
              .match(/[0-9.]+/g)?.slice(0, 3).map(Number);
            if (!channels || channels.length !== 3) {
              rail.style.setProperty("--whatscranio-control-color", "#3b4a54");
              return;
            }
            const linear = channels.map((channel) => {
              const value = channel / 255;
              return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
            });
            const luminance = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
            rail.style.setProperty(
              "--whatscranio-control-color",
              luminance > 0.4 ? "#3b4a54" : "#d1d7db"
            );
          };

          const createButton = ({ title, text, icon, tint, selected, action, accountID }) => {
            const button = document.createElement("button");
            button.type = "button";
            button.setAttribute("aria-label", title);
            button.dataset.tooltip = title;
            if (icon) {
              button.innerHTML = icon;
            } else {
              button.textContent = text;
            }
            button.style.cssText = [
              "width:40px", "height:40px", "min-height:40px", "border:0", "border-radius:12px",
              "display:flex", "align-items:center", "justify-content:center", "cursor:pointer",
              "font:600 13px -apple-system,BlinkMacSystemFont,sans-serif",
              tint ? "color:white" : "color:var(--whatscranio-control-color,var(--panel-header-icon,var(--icon,#54656f)))",
              "position:relative", "overflow:visible", "flex:0 0 auto",
              `background:${tint ? `#${tint.replace(/^#/, "")}` : "transparent"}`,
              selected ? "box-shadow:0 0 0 3px #21c063" : "box-shadow:none"
            ].join(";");

            const svg = button.querySelector("svg");
            if (svg) {
              svg.style.pointerEvents = "none";
              svg.style.display = "block";
            }

            let tooltip = document.getElementById("whatscranio-global-tooltip");
            if (!tooltip) {
              tooltip = document.createElement("span");
              tooltip.id = "whatscranio-global-tooltip";
              tooltip.setAttribute("role", "tooltip");
              tooltip.style.cssText = [
                "position:fixed", "transform:translate(-4px,-50%)", "opacity:0", "visibility:hidden",
                "padding:6px 9px", "border-radius:7px", "white-space:nowrap",
                "background:rgba(17,27,33,.97)", "border:1px solid rgba(255,255,255,.14)",
                "box-shadow:0 5px 18px rgba(0,0,0,.30)", "color:#f5f7f8",
                "font:500 12px -apple-system,BlinkMacSystemFont,sans-serif",
                "line-height:16px", "letter-spacing:0", "pointer-events:none",
                "z-index:2147483647", "transition:opacity .12s ease,transform .12s ease"
              ].join(";");
              document.body.appendChild(tooltip);
            }

            const showTooltip = () => {
              const bounds = button.getBoundingClientRect();
              tooltip.textContent = title;
              tooltip.style.left = `${bounds.right + 10}px`;
              tooltip.style.top = `${bounds.top + bounds.height / 2}px`;
              tooltip.style.visibility = "visible";
              tooltip.style.opacity = "1";
              tooltip.style.transform = "translate(0,-50%)";
            };
            const hideTooltip = () => {
              tooltip.style.opacity = "0";
              tooltip.style.transform = "translate(-4px,-50%)";
              tooltip.style.visibility = "hidden";
            };
            button.addEventListener("mouseenter", showTooltip);
            button.addEventListener("mouseleave", hideTooltip);
            button.addEventListener("focus", showTooltip);
            button.addEventListener("blur", hideTooltip);
            button.addEventListener("click", () => post(action, accountID));
            return button;
          };
          const mount = () => {
            window.__whatscranioDismissUnsupportedWebPrompts?.();
            const nativeRail = findRail();
            let fallbackRail = document.getElementById("whatscranio-fallback-rail");
            if (!nativeRail && !fallbackRail) {
              fallbackRail = document.createElement("div");
              fallbackRail.id = "whatscranio-fallback-rail";
              fallbackRail.style.cssText = "position:fixed;left:0;top:0;bottom:0;width:64px;z-index:2147483646;background:var(--panel-header-background,var(--background-default,#f0f2f5));display:flex;flex-direction:column;align-items:center;overflow-y:auto;overflow-x:hidden";
              document.body.appendChild(fallbackRail);
            }
            if (!nativeRail && fallbackRail) updateFallbackContrast(fallbackRail);
            const rail = nativeRail || fallbackRail;
            if (!rail) return false;
            let host = document.getElementById("whatscranio-integrated-controls");
            if (host && !rail.contains(host)) {
              host.remove();
              host = null;
            }
            if (nativeRail && fallbackRail) fallbackRail.remove();
            if (!host) {
              host = document.createElement("div");
              host.id = "whatscranio-integrated-controls";
              rail.insertBefore(host, rail.firstChild);
            }
            const signature = JSON.stringify(window.__whatscranioConfig);
            if (host.dataset.signature !== signature) {
              host.dataset.signature = signature;
              host.setAttribute("aria-label", "Ferramentas do WhatsCrânio");
              host.replaceChildren();
          host.appendChild(createButton({ title: "Adicionar conta", icon: icons.add, action: "addAccount" }));
          host.appendChild(createButton({ title: "Mensagens rápidas e agendamentos", icon: icons.automation, action: "openAutomation" }));
          host.appendChild(createButton({ title: "Preferências", icon: icons.settings, action: "openSettings" }));
          host.appendChild(createButton({ title: "Apoiar Tales Lima", icon: icons.donation, action: "openDonation" }));
          host.appendChild(createButton({ title: "Bloquear WhatsCrânio", icon: icons.lock, action: "lock" }));
            }

            if (nativeRail) {
              host.style.cssText = "display:flex;flex-direction:column;align-items:center;gap:7px;padding:8px 4px 9px;border:0;width:48px;position:fixed;z-index:2147483646;background:transparent;box-sizing:border-box";
              const chatButton = findChatButton();
              const chatRect = chatButton?.getBoundingClientRect();
              if (chatRect) host.style.left = `${chatRect.left + chatRect.width / 2 - 24}px`;

              const controlsHeight = host.getBoundingClientRect().height;
              const occupied = Array.from(nativeRail.querySelectorAll('button, [role="button"]'))
                .filter((button) => !host.contains(button))
                .map((button) => button.getBoundingClientRect())
                .filter((rect) => rect.width > 0 && rect.height > 0)
                .sort((left, right) => left.top - right.top);
              const gaps = [];
              let cursor = 64;
              for (const rect of occupied) {
                if (rect.top > cursor) gaps.push({ start: cursor, end: rect.top });
                cursor = Math.max(cursor, rect.bottom);
              }
              if (cursor < window.innerHeight - 16) gaps.push({ start: cursor, end: window.innerHeight - 16 });
              const gap = gaps
                .filter((candidate) => candidate.end - candidate.start >= controlsHeight)
                .sort((left, right) => (right.end - right.start) - (left.end - left.start))[0];
              const top = gap
                ? gap.start + (gap.end - gap.start - controlsHeight) / 2
                : Math.max(64, window.innerHeight - controlsHeight - 16);
              host.style.top = `${top}px`;
              nativeRail.style.overflow = "visible";
            } else {
              host.style.cssText = "display:flex;flex-direction:column;align-items:center;gap:7px;padding:8px 4px 9px;border:0;width:64px;position:relative;background:transparent;box-sizing:border-box";
            }
            return true;
          };
          window.__whatscranioMount = mount;
          mount();
          if (!window.__whatscranioObserver) {
            window.__whatscranioObserver = new MutationObserver(() => window.__whatscranioMount?.());
            window.__whatscranioObserver.observe(document.documentElement, { childList: true, subtree: true });
          }
        })();
        """
        integratedNavigationScript = script
        webView.evaluateJavaScript(script)
    }

    func flushPersistentData() async {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { _ in
                continuation.resume()
            }
        }
    }

    func reload() {
        if webView.url == nil { loadWhatsAppIfNeeded() } else { webView.reload() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let integratedNavigationScript {
            webView.evaluateJavaScript(integratedNavigationScript)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              WebLinkRouting.shouldOpenExternally(url) else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if WebLinkRouting.shouldOpenExternally(url) {
            NSWorkspace.shared.open(url)
        } else if url.host?.lowercased() == "web.whatsapp.com" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    @discardableResult
    func queueAttachments(paths: [String], caption: String) -> Int {
        queuedAttachmentURLs = paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        queuedAttachmentCaption = trimmedCaption.isEmpty ? nil : caption
        preparedMessageMacroID = nil
        preparedMessageAutoSend = false
        preparedMessageCompletion = nil
        preparedSendClickIssued = false
        return queuedAttachmentURLs.count
    }

    func runPreparedMessageMacro(autoSend: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let macroID = UUID()
        preparedMessageMacroID = macroID
        preparedMessageAutoSend = autoSend
        preparedMessageCompletion = completion
        preparedSendClickIssued = false
        webView.window?.makeFirstResponder(webView)
        guard !queuedAttachmentURLs.isEmpty else {
            preparedMessageKind = .text
            if let text = queuedAttachmentCaption {
                insertChatText(text, macroID: macroID)
            } else {
                resolvePreparedMessage(success: false, macroID: macroID)
            }
            return
        }
        preparedMessageKind = .attachment
        openQueuedAttachmentPicker(kind: attachmentPickerKind, macroID: macroID)
    }

    func captureActiveChat(completion: @escaping (String?) -> Void) {
        let script = """
        (() => {
          const visible = (element) => {
            const rect = element?.getBoundingClientRect?.();
            const style = element ? window.getComputedStyle(element) : null;
            return !!rect && rect.width > 0 && rect.height > 0 && style?.display !== "none" && style?.visibility !== "hidden";
          };
          const exposed = (element) => {
            if (!visible(element)) return false;
            const rect = element.getBoundingClientRect();
            const topmost = document.elementFromPoint(
              rect.left + Math.min(rect.width / 2, 24),
              rect.top + Math.min(rect.height / 2, 24)
            );
            return !!topmost && (topmost === element || element.contains(topmost) || topmost.contains(element));
          };
          const clean = (value) => (value || "").replace(/\\s+/g, " ").trim();
          const ignored = /^(?:dados do perfil|profile details?|contact info|online|offline|digitando|typing|visto por último|last seen|pesquisar|search|mais opções|more options|ligação de vídeo|video call|ligação de voz|voice call)$/i;
          const labelFrom = (container) => {
            if (!container) return null;
            const candidates = Array.from(container.querySelectorAll('[title]')).filter(visible)
              .map((element) => clean(element.getAttribute("title")))
              .concat(Array.from(container.querySelectorAll('[aria-label]')).filter(visible)
                .map((element) => clean(element.getAttribute("aria-label"))));
            for (const value of candidates) {
              if (value && !ignored.test(value) && value.length <= 160) return value;
            }
            return null;
          };
          const main = document.querySelector("#main") || document.querySelector('[role="main"]');
          const composer = Array.from(main?.querySelectorAll('[contenteditable="true"][aria-label], [contenteditable="true"][data-placeholder]') || [])
            .filter(visible)
            .find((element) => /(?:digite uma mensagem para|type a message to)/i.test(
              element.getAttribute("aria-label") || element.getAttribute("data-placeholder") || ""
            ));
          const composerLabel = composer?.getAttribute("aria-label") || composer?.getAttribute("data-placeholder") || "";
          const composerMatch = composerLabel.match(/(?:digite uma mensagem para|type a message to)\\s+(.+)$/i);
          if (composerMatch?.[1]) return clean(composerMatch[1]);
          const headerLabel = labelFrom(main?.querySelector("header"));
          if (headerLabel) return headerLabel;
          const selected = document.querySelector('#pane-side [role="row"][aria-selected="true"], #pane-side [role="listitem"][aria-selected="true"], #pane-side [data-testid="cell-frame-container"][aria-selected="true"]');
          return labelFrom(selected);
        })();
        """

        webView.evaluateJavaScript(script) { result, _ in
            Task { @MainActor in
                let label = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(label?.isEmpty == false ? label : nil)
            }
        }
    }

    func activateChat(named target: String, completion: @escaping (Bool) -> Void) {
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else {
            completion(false)
            return
        }
        activateChat(
            named: cleanTarget,
            attempt: 0,
            didFillSearch: false,
            didOpenNewChat: false,
            shouldContinue: nil,
            completion: completion
        )
    }

    private func activateChat(
        named target: String,
        attempt: Int,
        didFillSearch: Bool,
        didOpenNewChat: Bool,
        shouldContinue: (() -> Bool)?,
        completion: @escaping (Bool) -> Void
    ) {
        guard shouldContinue?() ?? true else {
            completion(false)
            return
        }
        guard attempt < 60,
              webView.url?.scheme == "https",
              webView.url?.host == "web.whatsapp.com",
              let targetData = try? JSONSerialization.data(withJSONObject: target, options: .fragmentsAllowed),
              let targetLiteral = String(data: targetData, encoding: .utf8)
        else {
            completion(false)
            return
        }
        let didFillSearchLiteral = didFillSearch ? "true" : "false"
        let didOpenNewChatLiteral = didOpenNewChat ? "true" : "false"

        let script = """
        (() => {
          const target = \(targetLiteral);
          const clean = (value) => (value || "").replace(/\\s+/g, " ").trim();
          const normalized = (value) => clean(value).normalize("NFD").replace(/[\\u0300-\\u036f]/g, "").toLocaleLowerCase();
          const digitVariants = (value) => {
            const digits = (value || "").replace(/\\D/g, "");
            const variants = new Set(digits ? [digits] : []);
            if (digits.startsWith("55") && digits.length === 13 && digits[4] === "9") {
              variants.add(digits.slice(0, 4) + digits.slice(5));
            } else if (digits.startsWith("55") && digits.length === 12) {
              variants.add(digits.slice(0, 4) + "9" + digits.slice(4));
            }
            return Array.from(variants);
          };
          const targetDigits = target.replace(/\\D/g, "");
          const matches = (value) => {
            const candidate = clean(value);
            if (!candidate) return false;
            if (targetDigits.length >= 8) {
              return digitVariants(candidate).some((left) => digitVariants(target).some((right) =>
                left.length >= 8 && right.length >= 8 && (left.endsWith(right) || right.endsWith(left))
              ));
            }
            return normalized(candidate) === normalized(target);
          };
          const visible = (element) => {
            const rect = element?.getBoundingClientRect?.();
            const style = element ? window.getComputedStyle(element) : null;
            return !!rect && rect.width > 0 && rect.height > 0 && style?.display !== "none" && style?.visibility !== "hidden";
          };
          const exposed = (element) => {
            if (!visible(element)) return false;
            const rect = element.getBoundingClientRect();
            const topmost = document.elementFromPoint(
              rect.left + Math.min(rect.width / 2, 24),
              rect.top + Math.min(rect.height / 2, 24)
            );
            return !!topmost && (topmost === element || element.contains(topmost) || topmost.contains(element));
          };
          const labelValues = (container) => {
            if (!container) return [];
            const values = [];
            for (const element of [container, ...container.querySelectorAll('[title], [aria-label]')]) {
              values.push(element.getAttribute?.("title"), element.getAttribute?.("aria-label"));
            }
            return values.filter(Boolean).map(clean);
          };
          const activeLabel = () => {
            const main = document.querySelector("#main") || document.querySelector('[role="main"]');
            const composer = Array.from(main?.querySelectorAll('[contenteditable="true"][aria-label], [contenteditable="true"][data-placeholder]') || [])
              .filter(visible)
              .find((element) => /(?:digite uma mensagem para|type a message to)/i.test(
                element.getAttribute("aria-label") || element.getAttribute("data-placeholder") || ""
              ));
            const composerLabel = composer?.getAttribute("aria-label") || composer?.getAttribute("data-placeholder") || "";
            const composerMatch = composerLabel.match(/(?:digite uma mensagem para|type a message to)\\s+(.+)$/i);
            if (composerMatch?.[1]) return clean(composerMatch[1]);
            const header = main?.querySelector("header");
            if (!header) return null;
            const ignored = /^(?:dados do perfil|profile details?|contact info|online|offline|digitando|typing|visto por último|last seen|pesquisar|search|mais opções|more options|ligação de vídeo|video call|ligação de voz|voice call)$/i;
            const titles = Array.from(header.querySelectorAll('[title]')).map((element) => clean(element.getAttribute("title")));
            const labels = Array.from(header.querySelectorAll('[aria-label]')).map((element) => clean(element.getAttribute("aria-label")));
            return [...titles, ...labels].find((value) => value && !ignored.test(value) && value.length <= 160) || null;
          };
          const current = activeLabel();
          if (current && matches(current)) return { action: "active", label: current };

          if (targetDigits.length >= 8 && !\(didOpenNewChatLiteral)) {
            const newChatIcon = Array.from(document.querySelectorAll(
              '[data-icon="new-chat-outline"], [data-icon="new-chat"], [data-testid="chat-list-new-chat"]'
            )).filter(visible).find((icon) => visible(icon.closest('button, [role="button"], [tabindex="0"]')));
            const newChat = newChatIcon?.closest('button, [role="button"], [tabindex="0"]') || Array.from(document.querySelectorAll('button, [role="button"], [tabindex="0"], [aria-label], [title]'))
              .filter(visible)
              .find((element) => [
                element.getAttribute("aria-label"),
                element.getAttribute("title"),
                element.innerText
              ].filter(Boolean).map(clean).some((label) => /^(?:nova conversa|new chat)$/i.test(label)));
            if (newChat) {
              newChat.click();
              return { action: "open-new-chat" };
            }
          }

          const rows = Array.from(document.querySelectorAll('[role="listitem"], [role="row"], [data-testid="cell-frame-container"]'))
            .filter((element) => {
              if (!exposed(element)) return false;
              const rect = element.getBoundingClientRect();
              return rect.right <= window.innerWidth * 0.5;
            });
          const row = rows.find((candidate) => {
            if (labelValues(candidate).some(matches)) return true;
            const rowText = clean(candidate.innerText);
            if (targetDigits.length < 8 && normalized(rowText).startsWith(normalized(target) + " ")) {
              return true;
            }
            return (candidate.innerText || "").split(/\\n+/).map(clean).some(matches);
          });
          if (row) {
            const clickable = row.closest('[role="listitem"], [role="row"]') || row;
            const rect = clickable.getBoundingClientRect();
            return { action: "select", x: rect.left + rect.width / 2, y: rect.top + Math.min(rect.height / 2, 36) };
          }

          const searches = Array.from(document.querySelectorAll('[contenteditable="true"], input'))
            .filter(exposed)
            .filter((element) => /(?:pesquisar|search)/i.test([
              element.getAttribute("aria-label"),
              element.getAttribute("aria-placeholder"),
              element.getAttribute("placeholder"),
              element.getAttribute("data-placeholder")
            ].filter(Boolean).join(" ")));
          const search = (\(didOpenNewChatLiteral)
            ? searches.find((element) => /(?:nome|name|número|number|usuário|username)/i.test([
                element.getAttribute("aria-label"),
                element.getAttribute("aria-placeholder"),
                element.getAttribute("placeholder"),
                element.getAttribute("data-placeholder")
              ].filter(Boolean).join(" ")))
            : null) || searches[0];
          if (!search) return { action: "waiting" };
          const searchValue = clean(search.value || search.innerText || search.textContent);
          if (!matches(searchValue)) {
            search.focus();
            if (search.isContentEditable) {
              const selection = window.getSelection();
              const range = document.createRange();
              range.selectNodeContents(search);
              selection.removeAllRanges();
              selection.addRange(range);
              document.execCommand("insertText", false, target);
            } else {
              const prototype = search instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
              setter?.call(search, target);
              search.dispatchEvent(new InputEvent("input", {
                bubbles: true,
                inputType: "insertText",
                data: target
              }));
            }
            return { action: "search-filled" };
          }
          if (targetDigits.length >= 8 && \(didOpenNewChatLiteral) && \(didFillSearchLiteral) && \(attempt) >= 2) {
            const searchRect = search.getBoundingClientRect();
            const ignored = /^(?:voltar|back|número de telefone|phone number|novo grupo|new group|novo contato|new contact|end icon button)$/i;
            const result = Array.from(document.querySelectorAll('button, [role="button"]'))
              .filter((element) => {
                if (!exposed(element)) return false;
                const rect = element.getBoundingClientRect();
                if (rect.top < searchRect.bottom - 2 || rect.right > window.innerWidth * 0.5 || rect.height < 28) return false;
                const label = clean([
                  element.getAttribute("aria-label"),
                  element.getAttribute("title"),
                  element.innerText
                ].filter(Boolean).join(" "));
                return label && !ignored.test(label);
              })[0];
            if (result) {
              result.focus();
              return { action: "select-phone-result" };
            }
            if (\(attempt) >= 12) return { action: "failed" };
          }
          return { action: "waiting" };
        })();
        """

        let webSession: WebSession = self
        webView.evaluateJavaScript(script) { result, error in
            Task { @MainActor in
                if error != nil {
                    completion(false)
                    return
                }
                let payload = result as? [String: Any]
                switch payload?["action"] as? String {
                case "active":
                    completion(true)
                    return
                case "select":
                    if let x = payload?["x"] as? Double, let y = payload?["y"] as? Double {
                        webSession.performTrustedWebClick(x: x, y: y)
                    }
                case "open-new-chat":
                    try? await Task.sleep(for: .milliseconds(300))
                    webSession.activateChat(
                        named: target,
                        attempt: 0,
                        didFillSearch: false,
                        didOpenNewChat: true,
                        shouldContinue: shouldContinue,
                        completion: completion
                    )
                    return
                case "select-phone-result":
                    webSession.performTrustedWebReturn()
                    try? await Task.sleep(for: .milliseconds(450))
                    webSession.activateChat(
                        named: target,
                        attempt: attempt + 1,
                        didFillSearch: true,
                        didOpenNewChat: true,
                        shouldContinue: shouldContinue,
                        completion: completion
                    )
                    return
                case "failed":
                    completion(false)
                    return
                case "search-filled":
                    guard !didFillSearch else {
                        if attempt >= 6 {
                            completion(false)
                            return
                        }
                        break
                    }
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(attempt < 12 ? 300 : 500))
                webSession.activateChat(
                    named: target,
                    attempt: attempt + 1,
                    didFillSearch: didFillSearch || (payload?["action"] as? String == "search-filled"),
                    didOpenNewChat: didOpenNewChat,
                    shouldContinue: shouldContinue,
                    completion: completion
                )
            }
        }
    }

    func runMessageQueue(
        _ messages: [QueuedMessagePayload],
        intervalSeconds: Double,
        progress: @escaping (Int, String) -> Void,
        completion: @escaping (MessageQueueResult) -> Void
    ) {
        guard !messages.isEmpty else {
            completion(.failure("A fila não possui mensagens."))
            return
        }
        cancelMessageQueue(notify: false)
        let runID = UUID()
        activeQueueRunID = runID
        activeQueueCompletion = completion
        runQueueItem(
            messages,
            index: 0,
            intervalSeconds: intervalSeconds,
            runID: runID,
            progress: progress,
            completion: completion
        )
    }

    func cancelMessageQueue() {
        cancelMessageQueue(notify: true)
    }

    private func cancelMessageQueue(notify: Bool) {
        let queueCompletion = activeQueueCompletion
        activeQueueRunID = nil
        activeQueueCompletion = nil
        preparedMessageMacroID = nil
        queuedAttachmentURLs.removeAll()
        queuedAttachmentCaption = nil
        preparedMessageAutoSend = false
        preparedMessageCompletion = nil
        preparedSendClickIssued = false
        if notify {
            queueCompletion?(.cancelled)
        }
    }

    private func runQueueItem(
        _ messages: [QueuedMessagePayload],
        index: Int,
        intervalSeconds: Double,
        runID: UUID,
        progress: @escaping (Int, String) -> Void,
        completion: @escaping (MessageQueueResult) -> Void
    ) {
        guard activeQueueRunID == runID else {
            completion(.cancelled)
            return
        }
        guard messages.indices.contains(index) else {
            activeQueueRunID = nil
            activeQueueCompletion = nil
            completion(.success)
            return
        }

        let message = messages[index]
        progress(index, message.title)
        let queuedAttachmentCount = queueAttachments(paths: message.attachmentPaths, caption: message.body)
        guard queuedAttachmentCount == message.attachmentPaths.count else {
            activeQueueRunID = nil
            activeQueueCompletion = nil
            completion(.failure("A fila parou em “\(message.title)” porque um anexo não foi encontrado."))
            return
        }
        runPreparedMessageMacro(autoSend: true) { [weak self] success in
            guard let self else { return }
            guard self.activeQueueRunID == runID else {
                completion(.cancelled)
                return
            }
            guard success else {
                self.activeQueueRunID = nil
                self.activeQueueCompletion = nil
                completion(.failure("A fila parou em “\(message.title)”. Verifique se o chat está aberto e vazio."))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0.5, intervalSeconds)))
                self.runQueueItem(
                    messages,
                    index: index + 1,
                    intervalSeconds: intervalSeconds,
                    runID: runID,
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    private var attachmentPickerKind: AttachmentPickerKind {
        let mediaExtensions: Set<String> = [
            "avif", "gif", "heic", "heif", "jpeg", "jpg", "m4v", "mov", "mp4", "mpeg", "mpg", "png", "webp"
        ]
        return queuedAttachmentURLs.allSatisfy { mediaExtensions.contains($0.pathExtension.lowercased()) }
            ? .media
            : .document
    }

    private func openQueuedAttachmentPicker(kind: AttachmentPickerKind, macroID: UUID, attempt: Int = 0) {
        guard attempt < 80,
              preparedMessageMacroID == macroID,
              !queuedAttachmentURLs.isEmpty,
              webView.url?.scheme == "https",
              webView.url?.host == "web.whatsapp.com"
        else { return }

        let script = """
        (() => {
          const kind = "\(kind.rawValue)";
          const labelFor = (element) => [
            element.getAttribute?.("aria-label"),
            element.getAttribute?.("aria-placeholder"),
            element.getAttribute?.("data-placeholder"),
            element.getAttribute?.("placeholder"),
            element.getAttribute?.("title"),
            element.getAttribute?.("data-testid"),
            element.textContent
          ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim();
          const isVisible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
          };
          const clickTarget = (element, action) => {
            const target = element?.closest?.('[role="menuitem"], [role="button"], button, li') || element;
            if (!target) return null;
            const rect = target.getBoundingClientRect();
            return {
              action,
              x: rect.left + rect.width / 2,
              y: rect.top + rect.height / 2
            };
          };

          const optionPattern = kind === "media"
            ? /(?:fotos?(?: e | & )v[ií]deos?|photos?(?: and | & )videos?|galeria|gallery)/i
            : /(?:documentos?|documents?)/i;
          const option = Array.from(document.querySelectorAll('[role="menuitem"], [role="button"], button, li, span'))
            .filter(isVisible)
            .find((element) => optionPattern.test(labelFor(element)));
          if (option) return clickTarget(option, "select-picker");

          const attach = Array.from(document.querySelectorAll('button, [role="button"]'))
            .filter(isVisible)
            .find((element) => /^(?:anexar|attach|adicionar anexo|add attachment)(?:\\s|$)/i.test(labelFor(element)));
          if (attach) return clickTarget(attach, "open-menu");
          return { action: "waiting-for-chat" };
        })();
        """

        let webSession: WebSession = self
        webView.evaluateJavaScript(script) { result, _ in
            Task { @MainActor in
                if let payload = result as? [String: Any],
                   let x = payload["x"] as? Double,
                   let y = payload["y"] as? Double {
                    webSession.performTrustedWebClick(x: x, y: y)
                }
                try? await Task.sleep(for: .milliseconds(attempt < 8 ? 220 : 400))
                guard webSession.preparedMessageMacroID == macroID,
                      !webSession.queuedAttachmentURLs.isEmpty
                else { return }
                webSession.openQueuedAttachmentPicker(kind: kind, macroID: macroID, attempt: attempt + 1)
            }
        }
    }

    private func performTrustedWebClick(x: Double, y: Double) {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let viewPoint = NSPoint(x: x, y: y)
        let windowPoint = webView.convert(viewPoint, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return }
        // Route the events through the window so AppKit performs normal hit
        // testing down to WKWebView's internal content view. Calling
        // `mouseDown` directly on WKWebView stops at the wrapper view on
        // current WebKit builds, which leaves WhatsApp's send button untouched.
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func performTrustedWebReturn() {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else { return }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        if !queuedAttachmentURLs.isEmpty {
            let selectedURLs: [URL]
            if parameters.allowsMultipleSelection {
                selectedURLs = queuedAttachmentURLs
                queuedAttachmentURLs.removeAll()
            } else {
                selectedURLs = [queuedAttachmentURLs.removeFirst()]
            }
            completionHandler(selectedURLs)
            if let caption = queuedAttachmentCaption {
                let macroID = preparedMessageMacroID
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    insertAttachmentCaption(caption, macroID: macroID)
                }
            } else if let macroID = preparedMessageMacroID {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    resolvePreparedMessage(success: true, macroID: macroID)
                }
            }
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func insertAttachmentCaption(_ caption: String, macroID: UUID?, attempt: Int = 0) {
        guard attempt < 75,
              preparedMessageMacroID == macroID,
              webView.url?.scheme == "https",
              webView.url?.host == "web.whatsapp.com",
              queuedAttachmentCaption == caption,
              let captionData = try? JSONSerialization.data(withJSONObject: caption, options: .fragmentsAllowed),
              let captionLiteral = String(data: captionData, encoding: .utf8)
        else { return }

        let script = """
        (() => {
          const caption = \(captionLiteral);
          const currentText = (element) => (element.innerText || element.textContent || "").trim();
          const isVisible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            if (rect.width <= 0 || rect.height <= 0 || style.display === "none" || style.visibility === "hidden") {
              return false;
            }
            const topElement = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
            return topElement === element || element.contains(topElement);
          };
          const semanticText = (element) => {
            const values = [];
            for (const attribute of ["aria-label", "aria-placeholder", "placeholder", "data-placeholder"]) {
              const value = element.getAttribute(attribute);
              if (value) values.push(value);
            }
            return values.join(" ").trim();
          };
          const attachmentPreviewVisible = Array.from(document.querySelectorAll('[aria-label], [aria-placeholder], [data-placeholder], button, [role="button"], [role="tab"]'))
            .some((element) => {
              const label = semanticText(element) || element.textContent || "";
              return /(?:enviar|send)\\s+\\d+\\s+(?:item|itens|items?)(?:\\s+selecionad[oa]s?)?/i.test(label)
                || /(?:adicionar arquivo|add file|abrir (?:foto|photo))/i.test(label);
            });
          const candidates = Array.from(document.querySelectorAll('[contenteditable="true"]'))
            .filter((element) => {
              if (!isVisible(element)) return false;
              const semantics = semanticText(element);
              return /(?:legenda|caption)/i.test(semantics)
                || (attachmentPreviewVisible && /(?:digite uma mensagem|type a message)/i.test(semantics))
                || attachmentPreviewVisible;
            })
            .sort((left, right) => right.getBoundingClientRect().top - left.getBoundingClientRect().top);
          const target = candidates[0];
          if (!target) return "waiting";
          if (currentText(target) === caption.trim()) return "confirmed";
          if (currentText(target)) return "occupied";

          target.focus();
          if (document.activeElement !== target && !target.contains(document.activeElement)) {
            return "waiting";
          }
          return "ready";
        })();
        """

        let webSession: WebSession = self
        webView.evaluateJavaScript(script) { result, _ in
            Task { @MainActor in
                switch result as? String {
                case "confirmed":
                    webSession.resolvePreparedMessage(success: true, macroID: macroID)
                case "occupied":
                    webSession.resolvePreparedMessage(success: false, macroID: macroID)
                case "ready":
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(caption, forType: .string)
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: webSession.webView)
                    try? await Task.sleep(for: .milliseconds(350))
                    webSession.insertAttachmentCaption(caption, macroID: macroID, attempt: attempt + 1)
                default:
                    try? await Task.sleep(for: .milliseconds(200))
                    webSession.insertAttachmentCaption(caption, macroID: macroID, attempt: attempt + 1)
                }
            }
        }
    }

    private func insertChatText(_ text: String, macroID: UUID, attempt: Int = 0) {
        guard attempt < 80,
              preparedMessageMacroID == macroID,
              queuedAttachmentCaption == text,
              webView.url?.scheme == "https",
              webView.url?.host == "web.whatsapp.com",
              let textData = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
              let textLiteral = String(data: textData, encoding: .utf8)
        else { return }

        let script = """
        (() => {
          const text = \(textLiteral);
          const semantics = (element) => [
            element.getAttribute("aria-label"),
            element.getAttribute("aria-placeholder"),
            element.getAttribute("placeholder"),
            element.getAttribute("data-placeholder")
          ].filter(Boolean).join(" ");
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
          };
          const target = Array.from(document.querySelectorAll('[contenteditable="true"]'))
            .filter(visible)
            .find((element) => /(?:digite uma mensagem|type a message|mensagem|message)/i.test(semantics(element))
              && !/(?:legenda|caption)/i.test(semantics(element)));
          if (!target) return "waiting";
          const current = (target.innerText || target.textContent || "").trim();
          if (current === text.trim()) return "confirmed";
          if (current) return "occupied";
          target.focus();
          if (document.activeElement !== target && !target.contains(document.activeElement)) return "waiting";
          return "ready";
        })();
        """

        let webSession: WebSession = self
        webView.evaluateJavaScript(script) { result, _ in
            Task { @MainActor in
                switch result as? String {
                case "confirmed":
                    webSession.resolvePreparedMessage(success: true, macroID: macroID)
                case "occupied":
                    webSession.resolvePreparedMessage(success: false, macroID: macroID)
                case "ready":
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: webSession.webView)
                    try? await Task.sleep(for: .milliseconds(350))
                    webSession.insertChatText(text, macroID: macroID, attempt: attempt + 1)
                default:
                    try? await Task.sleep(for: .milliseconds(300))
                    webSession.insertChatText(text, macroID: macroID, attempt: attempt + 1)
                }
            }
        }
    }

    private func resolvePreparedMessage(success: Bool, macroID: UUID?) {
        guard preparedMessageMacroID == macroID else { return }
        guard success else {
            finishPreparedMessage(success: false, macroID: macroID)
            return
        }
        if preparedMessageAutoSend {
            sendPreparedMessage(macroID: macroID)
        } else {
            finishPreparedMessage(success: true, macroID: macroID)
        }
    }

    private func sendPreparedMessage(macroID: UUID?, attempt: Int = 0) {
        guard attempt < 100,
              preparedMessageMacroID == macroID,
              preparedMessageAutoSend,
              webView.url?.scheme == "https",
              webView.url?.host == "web.whatsapp.com"
        else {
            finishPreparedMessage(success: false, macroID: macroID)
            return
        }

        let kind = preparedMessageKind == .attachment ? "attachment" : "text"
        let clickIssued = preparedSendClickIssued ? "true" : "false"
        let script = """
        (() => {
          const kind = "\(kind)";
          const clickIssued = \(clickIssued);
          const labelFor = (element) => [
            element.getAttribute?.("aria-label"),
            element.getAttribute?.("aria-placeholder"),
            element.getAttribute?.("data-placeholder"),
            element.getAttribute?.("placeholder"),
            element.getAttribute?.("title"),
            element.textContent
          ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim();
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
          };
          const buttons = Array.from(document.querySelectorAll('button, [role="button"]')).filter(visible);
          const editors = Array.from(document.querySelectorAll('[contenteditable="true"]')).filter(visible);
          const composerCandidates = editors.filter((element) => kind === "attachment"
            ? /(?:legenda|caption|digite uma mensagem|type a message)/i.test(labelFor(element))
            : /(?:digite uma mensagem|type a message)/i.test(labelFor(element)));
          const composer = (composerCandidates.length ? composerCandidates : editors)
            .sort((left, right) => right.getBoundingClientRect().bottom - left.getBoundingClientRect().bottom)[0];
          const composerRect = composer?.getBoundingClientRect();
          const sendCandidates = buttons.filter((element) => kind === "attachment"
            ? /(?:enviar|send)\\s+\\d+\\s+(?:item|itens|items?)/i.test(labelFor(element))
            : /(?:^|\\s)(?:enviar|send)(?:\\s|$)/i.test(labelFor(element)));
          const distanceToComposer = (element) => {
            const rect = element.getBoundingClientRect();
            if (!composerRect) return -rect.bottom;
            const dx = (rect.left + rect.width / 2) - (composerRect.left + composerRect.width / 2);
            const dy = (rect.top + rect.height / 2) - (composerRect.top + composerRect.height / 2);
            return Math.hypot(dx, dy);
          };
          const send = sendCandidates.sort((left, right) => distanceToComposer(left) - distanceToComposer(right))[0];
          if (!clickIssued) {
            if (!send) return { action: "waiting" };
            send.click();
            return { action: "clicked" };
          }
          if (kind === "attachment") {
            const previewStillOpen = buttons.some((element) =>
              /(?:enviar|send)\\s+\\d+\\s+(?:item|itens|items?)/i.test(labelFor(element))
              || /(?:adicionar arquivo|add file)/i.test(labelFor(element)));
            return { action: previewStillOpen ? "waiting" : "sent" };
          }
          const content = (composer?.innerText || composer?.textContent || "").trim();
          // WhatsApp can keep unrelated/stale buttons labelled "Enviar" in
          // the DOM. The composer becoming empty is the reliable boundary fact
          // that the text was accepted after activating the selected control.
          return { action: composer && !content ? "sent" : "waiting" };
        })();
        """

        let webSession: WebSession = self
        webView.evaluateJavaScript(script) { result, _ in
            Task { @MainActor in
                guard webSession.preparedMessageMacroID == macroID else { return }
                let payload = result as? [String: Any]
                switch payload?["action"] as? String {
                case "clicked":
                    webSession.preparedSendClickIssued = true
                case "sent":
                    webSession.finishPreparedMessage(success: true, macroID: macroID)
                    return
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(attempt < 10 ? 250 : 450))
                webSession.sendPreparedMessage(macroID: macroID, attempt: attempt + 1)
            }
        }
    }

    private func finishPreparedMessage(success: Bool, macroID: UUID?) {
        guard preparedMessageMacroID == macroID else { return }
        let completion = preparedMessageCompletion
        queuedAttachmentURLs.removeAll()
        queuedAttachmentCaption = nil
        preparedMessageMacroID = nil
        preparedMessageAutoSend = false
        preparedMessageCompletion = nil
        preparedSendClickIssued = false
        completion?(success)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        guard origin.protocol == "https", origin.host == "web.whatsapp.com" else {
            decisionHandler(.deny)
            return
        }

        switch type {
        case .microphone:
            decisionHandler(.grant)
        case .camera, .cameraAndMicrophone:
            decisionHandler(.prompt)
        @unknown default:
            decisionHandler(.deny)
        }
    }
}

@MainActor
final class WebSessionPool {
    static let shared = WebSessionPool()
    private var sessions: [UUID: WebSession] = [:]
    private var accounts: [WebAccount] = []
    private var selectedAccountID: UUID?
    private var actionHandler: ((WebAppAction) -> Void)?

    func session(for account: WebAccount) -> WebSession {
        if let existing = sessions[account.id] { return existing }
        let session = WebSession(account: account)
        session.actionBridge.handler = actionHandler
        sessions[account.id] = session
        if let selectedAccountID {
            session.updateIntegratedNavigation(accounts: accounts, selectedAccountID: selectedAccountID)
        }
        return session
    }

    func configureNavigation(
        accounts: [WebAccount],
        selectedAccountID: UUID,
        actionHandler: @escaping (WebAppAction) -> Void
    ) {
        self.accounts = accounts
        self.selectedAccountID = selectedAccountID
        self.actionHandler = actionHandler
        for session in sessions.values {
            session.actionBridge.handler = actionHandler
            session.updateIntegratedNavigation(accounts: accounts, selectedAccountID: selectedAccountID)
        }
    }

    func prewarm(accounts: [WebAccount]) {
        for account in accounts {
            _ = session(for: account)
        }
    }

    func discard(accountID: UUID) {
        sessions[accountID] = nil
    }

    func remove(account: WebAccount) {
        discard(accountID: account.id)
        WKWebsiteDataStore.remove(forIdentifier: account.dataStoreID) { _ in }
    }

    func flushPersistentData() async {
        for session in Array(sessions.values) {
            await session.flushPersistentData()
        }
    }
}

struct WhatsAppWebContainer: NSViewRepresentable {
    let account: WebAccount

    func makeNSView(context: Context) -> WKWebView {
        WebSessionPool.shared.session(for: account).webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        WebSessionPool.shared.session(for: account).loadWhatsAppIfNeeded()
    }
}
