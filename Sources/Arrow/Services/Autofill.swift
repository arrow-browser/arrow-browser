import AppKit
import ArrowKit
import Foundation
import Security

/// Saved logins, as internet passwords in the login Keychain (Preferences ▸
/// Profiles ▸ Passwords). Only items created by Arrow are listed.
@MainActor
enum PasswordStore {
    struct Login: Identifiable, Hashable {
        var id: String { host + "\n" + username }
        let host: String
        let username: String
        let modified: Date?
    }

    private static let itemDescription = "Arrow saved login"

    static func logins(for host: String? = nil) -> [Login] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: itemDescription,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let host { query[kSecAttrServer as String] = host }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let server = item[kSecAttrServer as String] as? String else { return nil }
            return Login(host: server, username: item[kSecAttrAccount as String] as? String ?? "",
                         modified: item[kSecAttrModificationDate as String] as? Date)
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    static func password(host: String, username: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(host: host, username: username).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(host: String, username: String, password: String) {
        let data = Data(password.utf8)
        let base = query(host: host, username: username)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging([
                kSecValueData as String: data,
                kSecAttrLabel as String: host,
                kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            ]) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(host: String, username: String) {
        SecItemDelete(query(host: host, username: username) as CFDictionary)
    }

    private static func query(host: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrDescription as String: itemDescription,
        ]
    }
}

/// Saved payment cards, as generic passwords in the login Keychain
/// (Preferences ▸ Profiles ▸ Credit Cards).
@MainActor
enum CardStore {
    private static let service = "Arrow Payment Cards"

    static func cards() -> [PaymentCard] {
        // The file-based keychain returns data for one item at a time only.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> PaymentCard? in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            var data: CFTypeRef?
            let one: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
            return try? JSONDecoder().decode(PaymentCard.self, from: data)
        }
        .sorted { $0.label < $1.label }
    }

    static func save(_ card: PaymentCard) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: card.id.uuidString,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging([kSecValueData as String: data, kSecAttrLabel as String: card.label]) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(_ card: PaymentCard) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: card.id.uuidString,
        ] as CFDictionary)
    }
}

/// Banner offered over a page: save or fill a password or a card, translate.
struct PageOffer: Identifiable {
    enum Kind {
        case savePassword(host: String, username: String, password: String)
        case saveCard(PaymentCard)
        case fillPassword(host: String, usernames: [String])
        case fillCard([PaymentCard])
        case translate(language: String)
    }

    let id = UUID()
    let kind: Kind
}

// MARK: - Page scripts

enum AutofillScripts {
    /// Reports submitted logins and cards (`__arrow_login__`, `__arrow_card__`)
    /// and focused card fields (`__arrow_card_focus__`).
    static let observer = """
    (() => {
      if (window.__arrowAutofill || window !== window.top) return;
      window.__arrowAutofill = true;
      const cardSelector = 'input[autocomplete="cc-number"], input[name*="cardnumber" i], input[id*="cardnumber" i], '
        + 'input[name*="card_number" i], input[id*="card-number" i], input[name*="ccnumber" i]';
      const visible = (el) => el && el.offsetParent !== null && !el.disabled;
      const usernameFor = (password) => {
        const scope = password.form || document;
        const inputs = [...scope.querySelectorAll('input')].filter(visible);
        for (let i = inputs.indexOf(password) - 1; i >= 0; i--) {
          const type = (inputs[i].type || 'text').toLowerCase();
          if (['text', 'email', 'tel'].includes(type)) return inputs[i];
        }
        return scope.querySelector('input[autocomplete="username"], input[type="email"]');
      };
      let last = '';
      const report = (scope) => {
        scope = scope || document;
        const password = [...scope.querySelectorAll('input[type="password"]')].find((p) => p.value);
        if (password) {
          const user = usernameFor(password);
          const login = JSON.stringify({ username: user ? user.value : '', password: password.value });
          if (login !== last) { last = login; console.debug('__arrow_login__:' + login); }
        }
        const number = scope.querySelector(cardSelector);
        if (number && number.value) {
          const field = (selector) => scope.querySelector(selector);
          const name = field('input[autocomplete="cc-name"], input[name*="cardholder" i], input[name*="ccname" i]');
          const expiry = field('input[autocomplete="cc-exp"]');
          const month = field('[autocomplete="cc-exp-month"]'), year = field('[autocomplete="cc-exp-year"]');
          console.debug('__arrow_card__:' + JSON.stringify({
            number: number.value, name: name ? name.value : '',
            expiry: expiry ? expiry.value : (month && year ? month.value + '/' + year.value : '') }));
        }
      };
      document.addEventListener('submit', (event) => report(event.target), true);
      document.addEventListener('click', (event) => {
        const button = event.target.closest && event.target.closest('button, input[type="submit"]');
        if (button) report(button.form || button.closest('form'));
      }, true);
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && event.target.type === 'password') report(event.target.form);
      }, true);
      document.addEventListener('focusin', (event) => {
        if (event.target.matches && event.target.matches(cardSelector)) console.debug('__arrow_card_focus__');
      }, true);
    })();
    """

    /// Whether the page shows a password field.
    static let hasPasswordField = "!!document.querySelector('input[type=\"password\"]')"

    static func fillLogin(username: String, password: String) -> String {
        let values = jsonString(["username": username, "password": password])
        return """
        ((login) => {
          const visible = (el) => el && el.offsetParent !== null && !el.disabled && !el.readOnly;
          const set = (el, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const password = [...document.querySelectorAll('input[type="password"]')].find(visible);
          const scope = (password && password.form) || document;
          const inputs = [...scope.querySelectorAll('input')].filter(visible);
          let user = null;
          for (let i = (password ? inputs.indexOf(password) : inputs.length) - 1; i >= 0; i--) {
            if (['text', 'email', 'tel'].includes((inputs[i].type || 'text').toLowerCase())) { user = inputs[i]; break; }
          }
          if (user && !user.value && login.username) set(user, login.username);
          if (password) set(password, login.password);
          return !!password;
        })(\(values))
        """
    }

    static func fillCard(_ card: PaymentCard) -> String {
        let values = jsonString([
            "number": card.number, "name": card.holder, "month": String(format: "%02d", card.expiryMonth),
            "year": String(card.expiryYear), "expiry": card.expiry,
        ])
        return """
        ((card) => {
          const set = (el, value) => {
            if (!el) return;
            if (el.tagName === 'SELECT') {
              const option = [...el.options].find((o) => o.value.endsWith(value) || o.text.endsWith(value)
                || o.value === String(Number(value)));
              if (option) el.value = option.value;
            } else {
              Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const field = (selector) => document.querySelector(selector);
          set(field('input[autocomplete="cc-number"], input[name*="cardnumber" i], input[id*="cardnumber" i], '
            + 'input[name*="card_number" i], input[id*="card-number" i], input[name*="ccnumber" i]'), card.number);
          set(field('input[autocomplete="cc-name"], input[name*="cardholder" i], input[name*="ccname" i]'), card.name);
          set(field('input[autocomplete="cc-exp"]'), card.expiry);
          set(field('[autocomplete="cc-exp-month"]'), card.month);
          set(field('[autocomplete="cc-exp-year"]'), card.year);
        })(\(values))
        """
    }

    private static func jsonString(_ values: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - Tab integration

extension WebTab {
    private var pageHost: String? { URLDisplay.host(of: url) }

    /// After a page loads: the observer, fill offers and the translate prompt.
    func runAutofill(_ browser: CEFBrowser) {
        guard let store, url.hasPrefix("http") else { return }
        if case .fillPassword? = offer?.kind { offer = nil }
        if case .fillCard? = offer?.kind { offer = nil }
        if case .translate? = offer?.kind { offer = nil }
        browser.executeJavaScript(AutofillScripts.observer, scriptURL: "arrow://autofill")
        if let host = pageHost, store.settings.offerToSavePasswords {
            let logins = PasswordStore.logins(for: host)
            if !logins.isEmpty {
                Task {
                    // Chromium's values come back as numbers for booleans.
                    let field = await browser.evaluateJavaScript(AutofillScripts.hasPasswordField)
                    guard (field as? Bool) ?? ((field as? Int).map { $0 != 0 } ?? false) else { return }
                    if logins.count == 1 {
                        fill(login: logins[0])
                    } else {
                        offer = PageOffer(kind: .fillPassword(host: host, usernames: logins.map(\.username)))
                    }
                }
            }
        }
        offerTranslation(browser, settings: store.settings)
    }

    private func offerTranslation(_ browser: CEFBrowser, settings: ArrowSettings) {
        Task {
            let language = await browser.evaluateJavaScript("document.documentElement.lang") as? String
            guard PageTranslation.shouldOffer(pageLanguage: language, userLanguages: Locale.preferredLanguages, url: url,
                                              neverLanguages: settings.neverTranslateLanguages,
                                              neverSites: settings.neverTranslateSites),
                  offer == nil, let language else { return }
            offer = PageOffer(kind: .translate(language: PageTranslation.baseLanguage(language)))
        }
    }

    /// Messages of the observer script; true when handled.
    func handleAutofillMessage(_ message: String) -> Bool {
        guard let store else { return false }
        if message.hasPrefix("__arrow_login__:") {
            guard store.settings.offerToSavePasswords, !isIncognito, let host = pageHost,
                  !store.settings.neverSavePasswordSites.contains(URLDisplay.registrableDomain(host)),
                  let login = decode(message, prefix: "__arrow_login__:"),
                  let password = login["password"], !password.isEmpty else { return true }
            let username = login["username"] ?? ""
            if PasswordStore.password(host: host, username: username) != password {
                offer = PageOffer(kind: .savePassword(host: host, username: username, password: password))
            }
            return true
        }
        if message.hasPrefix("__arrow_card__:") {
            guard store.settings.autofillCards, !isIncognito, let card = decode(message, prefix: "__arrow_card__:"),
                  let number = card["number"], PaymentCard.isValidNumber(number) else { return true }
            let digits = number.filter(\.isNumber)
            guard !CardStore.cards().contains(where: { $0.number == digits }) else { return true }
            let expiry = card["expiry"].flatMap(PaymentCard.parseExpiry)
            offer = PageOffer(kind: .saveCard(PaymentCard(holder: card["name"] ?? "", number: digits,
                                                          expiryMonth: expiry?.month ?? 1, expiryYear: expiry?.year ?? 2000)))
            return true
        }
        if message == "__arrow_card_focus__" {
            let cards = CardStore.cards()
            // Filling the field being typed in comes before a translation offer.
            var isTranslating = false
            if case .translate? = offer?.kind { isTranslating = true }
            if store.settings.autofillCards, !cards.isEmpty, offer == nil || isTranslating {
                offer = PageOffer(kind: .fillCard(cards))
            }
            return true
        }
        return false
    }

    func fill(login: PasswordStore.Login) {
        guard let password = PasswordStore.password(host: login.host, username: login.username) else { return }
        engine?.executeJavaScript(AutofillScripts.fillLogin(username: login.username, password: password),
                                  scriptURL: "arrow://autofill")
    }

    func fill(card: PaymentCard) {
        engine?.executeJavaScript(AutofillScripts.fillCard(card), scriptURL: "arrow://autofill")
    }

    private func decode(_ message: String, prefix: String) -> [String: String]? {
        try? JSONDecoder().decode([String: String].self, from: Data(message.dropFirst(prefix.count).utf8))
    }
}

// MARK: - Offer decisions

extension WebTab {
    /// "Save" (password or card), "Translate".
    func acceptOffer() {
        guard let offer else { return }
        switch offer.kind {
        case let .savePassword(host, username, password):
            PasswordStore.save(host: host, username: username, password: password)
        case let .saveCard(card):
            CardStore.save(card)
        case let .fillPassword(host, usernames):
            if let username = usernames.first { fill(login: PasswordStore.Login(host: host, username: username, modified: nil)) }
        case let .fillCard(cards):
            if let card = cards.first { fill(card: card) }
        case .translate:
            let target = PageTranslation.baseLanguage(Locale.preferredLanguages.first ?? "en")
            if let translated = PageTranslation.url(for: url, to: target) { engine?.load(url: translated) }
        }
        self.offer = nil
    }

    /// "Never": this site (passwords) or this language (translation).
    func neverOffer(forSite: Bool = true) {
        guard let offer, let store else { return }
        switch offer.kind {
        case let .savePassword(host, _, _):
            store.settings.neverSavePasswordSites.append(URLDisplay.registrableDomain(host))
        case let .translate(language):
            if forSite, let host = URLDisplay.host(of: url) {
                store.settings.neverTranslateSites.append(URLDisplay.registrableDomain(host))
            } else {
                store.settings.neverTranslateLanguages.append(language)
            }
        default:
            break
        }
        self.offer = nil
    }

    var offerDescription: String {
        switch offer?.kind {
        case let .savePassword(host, username, _)?: "savePassword \(host) \(username)"
        case let .saveCard(card)?: "saveCard \(card.label) \(card.expiry)"
        case let .fillPassword(host, usernames)?: "fillPassword \(host) \(usernames)"
        case let .fillCard(cards)?: "fillCard \(cards.map(\.label))"
        case let .translate(language)?: "translate \(language)"
        case nil: "none"
        }
    }
}
