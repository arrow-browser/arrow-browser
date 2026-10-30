import ArrowCore
import ArrowKit
import SwiftUI

/// Creates or edits a Boost: page colors, font, zapped elements, custom
/// CSS and JavaScript. Changes preview live on the current page.
struct BoostEditorView: View {
    let controller: BrowserWindowController
    let boostID: UUID?
    let url: String?
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var boost = Boost(name: "", domain: "")
    @State private var zapText = ""
    @State private var didLoad = false
    @State private var tab = 0

    private static let fonts = ["", "SF Pro", "New York", "SF Mono", "Helvetica Neue", "Avenir Next", "Georgia", "Menlo",
                                "Futura", "Gill Sans", "Baskerville", "Optima", "Inter", "Comic Sans MS"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FaviconView(url: "https://\(boost.domain)", size: 20)
                TextField("Boost name", text: $boost.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                Spacer()
                Toggle("Enabled", isOn: $boost.isEnabled)
                    .toggleStyle(.switch)
            }
            .padding(14)
            Divider()
            Picker("", selection: $tab) {
                Text("Style").tag(0)
                Text("Zap").tag(1)
                Text("Code").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Form {
                switch tab {
                case 0: styleSection
                case 1: zapSection
                default: codeSection
                }
            }
            .formStyle(.grouped)

            HStack {
                if boostID != nil {
                    Button("Delete Boost", role: .destructive) {
                        store.deleteBoost(boost.id)
                        controller.selectedTab?.reload()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") {
                    controller.selectedTab?.reload()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    applyZaps()
                    store.saveBoost(boost)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(boost.domain.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 620)
        .onAppear(perform: load)
        .onChange(of: boost) { _, _ in preview() }
    }

    @ViewBuilder
    private var styleSection: some View {
        TextField("Website", text: $boost.domain)
        Section("Colors") {
            Slider(value: Binding(get: { boost.hueRotation ?? 0 }, set: { boost.hueRotation = $0 }), in: -180...180) {
                Text("Hue")
            }
            Slider(value: Binding(get: { boost.saturation ?? 1 }, set: { boost.saturation = $0 }), in: 0...2) {
                Text("Saturation")
            }
            Slider(value: Binding(get: { boost.brightness ?? 1 }, set: { boost.brightness = $0 }), in: 0.5...1.5) {
                Text("Brightness")
            }
            Toggle("Invert (dark mode)", isOn: $boost.invertColors)
        }
        Section("Typography") {
            Picker("Font", selection: Binding(get: { boost.fontFamily ?? "" }, set: { boost.fontFamily = $0.isEmpty ? nil : $0 })) {
                ForEach(Self.fonts, id: \.self) { font in
                    Text(font.isEmpty ? "Website default" : font).tag(font)
                }
            }
            Slider(value: Binding(get: { boost.fontScale ?? 1 }, set: { boost.fontScale = $0 }), in: 0.7...1.6) {
                Text("Text size")
            }
        }
    }

    @ViewBuilder
    private var zapSection: some View {
        Section {
            TextEditor(text: $zapText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
        } header: {
            Text("Hidden elements")
        } footer: {
            Text("One CSS selector per line (e.g. `.sidebar`, `#cookie-banner`). Matching elements are hidden.")
        }
    }

    @ViewBuilder
    private var codeSection: some View {
        Section("CSS") {
            TextEditor(text: $boost.css)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
        }
        Section("JavaScript") {
            TextEditor(text: $boost.javaScript)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let boostID, let existing = store.boosts.first(where: { $0.id == boostID }) {
            boost = existing
        } else {
            let domain = url.flatMap { URLDisplay.host(of: $0) } ?? ""
            boost = Boost(name: domain.isEmpty ? "New Boost" : "\(domain) Boost", domain: domain)
        }
        zapText = boost.zappedSelectors.joined(separator: "\n")
    }

    private func applyZaps() {
        boost.zappedSelectors = zapText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Live preview on the current page.
    private func preview() {
        guard let tab = controller.selectedTab, boost.applies(to: tab.url) || boost.domain.isEmpty == false else { return }
        var previewBoost = boost
        previewBoost.zappedSelectors = zapText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        previewBoost.javaScript = ""
        tab.engine?.executeJavaScript(previewBoost.injectionScript, scriptURL: "arrow://boost-preview")
    }
}
