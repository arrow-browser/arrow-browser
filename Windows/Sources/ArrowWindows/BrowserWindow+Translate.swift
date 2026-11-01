import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinSDK
import WindowsFoundation
import WinUI

/// Arc's Translate (the globe of the toolbar): a flyout offering to
/// translate the page into the user's language, in the page itself, with
/// Options (another language, never this site, language settings).
extension BrowserWindow {
    /// Languages offered by Choose Another Language.
    static let translationLanguages = ["en", "fr", "de", "es", "it", "pt", "nl", "pl", "ru", "ja", "ko", "zh-CN", "ar"]

    /// The user's language, Windows' display language, as Google Translate
    /// names it.
    static var userLanguage: String {
        var buffer = [WCHAR](repeating: 0, count: 85)  // LOCALE_NAME_MAX_LENGTH
        let length = LCIDToLocaleName(DWORD(GetUserDefaultUILanguage()), &buffer, Int32(buffer.count), 0)
        let code = length > 1 ? String(decoding: buffer.prefix(Int(length) - 1), as: UTF16.self) : "en"
        return code.hasPrefix("zh") ? "zh-CN" : String(code.prefix(2))
    }

    /// A language's name in that language ("français").
    static func languageName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    /// Arc's Translate: a teaching tip pointing at the toolbar's globe.
    func showTranslate(under anchor: FrameworkElement) {
        guard let tab = selectedTab else { return }
        let tip = TeachingTip()
        tip.shouldConstrainToRootBounds = false
        tip.preferredPlacement = .bottom
        tip.isLightDismissEnabled = true
        let content = StackPanel()
        content.spacing = 8
        let question = TextBlock()
        let isTranslated = translatedTabs[tab.id] == tab.url
        question.text = isTranslated
            ? "This page is translated."
            : "Translate this page to \(Self.languageName(Self.userLanguage))?"
        content.children.append(question)
        let buttons = StackPanel()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let primary = Button()
        primary.content = isTranslated ? "Show Original" : "Translate"
        primary.minWidth = 103
        primary.height = 34
        primary.click.addHandler { [weak self] _, _ in
            tip.isOpen = false
            if isTranslated {
                self?.showOriginal(tab)
            } else {
                self?.translate(tab, to: Self.userLanguage)
            }
        }
        let options = Button()
        options.content = "Options"
        options.minWidth = 103
        options.height = 34
        options.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            Menu.show(translateOptions(for: tab, closing: tip), above: options)
        }
        buttons.children.append(primary)
        buttons.children.append(options)
        content.children.append(buttons)
        tip.content = content
        show(tip, pointingAt: anchor)
    }

    private func translateOptions(for tab: WebTab, closing tip: TeachingTip) -> MenuFlyout {
        let host = URLDisplay.host(of: tab.url).map(URLDisplay.registrableDomain) ?? ""
        return Menu.flyout([
            Menu.submenu("Choose Another Language", Self.translationLanguages.map { code in
                Menu.item(Self.languageName(code).capitalized) { [weak self] in
                    tip.isOpen = false
                    self?.translate(tab, to: code)
                }
            }),
            Menu.item("Never Translate This Site", isEnabled: !host.isEmpty) { [weak self] in
                tip.isOpen = false
                guard let self, !store.settings.neverTranslateSites.contains(host) else { return }
                store.settings.neverTranslateSites.append(host)
            },
            Menu.item("Language Settings") {
                tip.isOpen = false
                SettingsWindow.show(section: .general)
            },
        ])
    }

    /// Translates the page in place with Google's website translator; where
    /// the site refuses its script, opens Google's translated copy.
    func translate(_ tab: WebTab, to language: String) {
        guard let engine = tab.engine else { return }
        let page = tab.url
        translatedTabs[tab.id] = page
        engine.executeJavaScript(Self.translateScript(language), scriptURL: "arrow://translate")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            let translated = await engine.evaluateJavaScript(
                "document.documentElement.className.indexOf('translated') >= 0") as? Bool
            // Unless the user went to another page meanwhile.
            guard translated != true, tab.url == page, let url = PageTranslation.url(for: page, to: language) else {
                return
            }
            self?.translatedTabs[tab.id] = nil
            tab.load(url)
        }
    }

    func showOriginal(_ tab: WebTab) {
        translatedTabs[tab.id] = nil
        tab.reload()
    }

    /// Loads Google's website translator in the page, hidden, and has it
    /// translate to `language`.
    static func translateScript(_ language: String) -> String {
        """
        (function (language) {
          function pick() {
            var tries = 0;
            (function choose() {
              var combo = document.querySelector('.goog-te-combo');
              if (combo && combo.options.length > 1) {
                combo.value = language;
                combo.dispatchEvent(new Event('change'));
              } else if (tries++ < 80) {
                setTimeout(choose, 100);
              }
            })();
          }
          if (window.__arrowTranslate) { pick(); return; }
          window.__arrowTranslate = true;
          var host = document.createElement('div');
          host.id = 'arrow_translate';
          host.style.display = 'none';
          document.body.appendChild(host);
          var style = document.createElement('style');
          style.textContent = '.goog-te-banner-frame, .skiptranslate, #goog-gt-tt { display: none !important; }'
            + ' body { top: 0 !important; }';
          document.head.appendChild(style);
          window.arrowTranslateReady = function () {
            new google.translate.TranslateElement({ pageLanguage: 'auto', autoDisplay: false }, 'arrow_translate');
            pick();
          };
          var script = document.createElement('script');
          script.src = 'https://translate.google.com/translate_a/element.js?cb=arrowTranslateReady';
          document.head.appendChild(script);
        })('\(language)');
        """
    }
}
