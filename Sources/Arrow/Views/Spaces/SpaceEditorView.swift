import ArrowCore
import ArrowKit
import SwiftUI

/// Creates or edits a space: name, icon, theme (gradient colors, harmony,
/// light/dark, intensity, grain) and profile.
struct SpaceEditorView: View {
    let controller: BrowserWindowController
    let spaceID: UUID?
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var title = ""
    @State private var icon: SpaceIcon?
    @State private var emoji = ""
    @State private var primary = Color(RGBColor(hex: 0x9A8CFF))
    @State private var harmony: ColorHarmony = .analogous
    @State private var appearance: ThemeAppearance = .automatic
    @State private var intensity = 0.3
    @State private var grain = 0.15
    @State private var profileID: UUID?
    @State private var didLoad = false

    private static let symbols = [
        "circle.fill", "person.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill",
        "leaf.fill", "book.fill", "graduationcap.fill", "gamecontroller.fill", "music.note", "camera.fill", "cart.fill",
        "airplane", "hammer.fill", "paintbrush.fill", "globe", "moon.fill", "sun.max.fill", "cloud.fill", "sparkles", "atom",
    ]

    private var theme: SpaceTheme {
        SpaceTheme(primary: RGBColor(NSColor(primary)), harmony: harmony, appearance: appearance, intensity: intensity, grain: grain)
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            Form {
                TextField("Name", text: $title)
                Section("Icon") {
                    HStack {
                        TextField("Emoji", text: $emoji)
                            .frame(width: 80)
                            .onChange(of: emoji) { _, value in
                                if let first = value.first {
                                    emoji = String(first)
                                    icon = .emoji(String(first))
                                }
                            }
                        Button("None") {
                            icon = nil
                            emoji = ""
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 12), spacing: 6) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(icon == .symbol(symbol) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                                .onTapGesture {
                                    icon = .symbol(symbol)
                                    emoji = ""
                                }
                        }
                    }
                }
                Section("Theme") {
                    HStack(spacing: 8) {
                        ForEach(Array(SpaceTheme.presets.enumerated()), id: \.offset) { _, preset in
                            Circle()
                                .fill(Color(preset.primary))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                                .shadow(radius: 1)
                                .onTapGesture {
                                    primary = Color(preset.primary)
                                    harmony = preset.harmony
                                }
                        }
                        ColorPicker("", selection: $primary, supportsOpacity: false)
                            .labelsHidden()
                    }
                    Picker("Gradient", selection: $harmony) {
                        Text("Single").tag(ColorHarmony.single)
                        Text("Analogous").tag(ColorHarmony.analogous)
                        Text("Complementary").tag(ColorHarmony.complementary)
                        Text("Triadic").tag(ColorHarmony.triadic)
                    }
                    Picker("Appearance", selection: $appearance) {
                        Image(systemName: "sun.max").tag(ThemeAppearance.light)
                        Image(systemName: "circle.lefthalf.filled").tag(ThemeAppearance.automatic)
                        Image(systemName: "moon").tag(ThemeAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                    Slider(value: $intensity, in: 0...1) { Text("Intensity") }
                    Slider(value: $grain, in: 0...1) { Text("Grain") }
                }
                Section("Profile") {
                    Picker("Profile", selection: $profileID) {
                        ForEach(store.state.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    Text("Logins, cookies and history are separate for each profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let spaceID, store.state.spaces.count > 1 {
                    Button("Delete Space", role: .destructive) {
                        store.update { $0.deleteSpace(spaceID) }
                        if let first = store.state.spaces.first { controller.selectSpace(first.id) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(spaceID == nil ? "Create Space" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 480, height: 680)
        .onAppear(perform: load)
    }

    private var preview: some View {
        let palette = theme.palette(isDark: theme.isDark(systemIsDark: colorScheme == .dark))
        return ZStack {
            ThemeBackground(palette: palette)
            HStack(spacing: 8) {
                SpaceIconView(icon: icon, size: 15)
                Text(title.isEmpty ? "New Space" : title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color(palette.title))
        }
        .frame(height: 96)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let spaceID, let space = store.state.space(spaceID) {
            title = space.title
            icon = space.icon
            if case let .emoji(value) = space.icon { emoji = value }
            primary = Color(space.theme.primary)
            harmony = space.theme.harmony
            appearance = space.theme.appearance
            intensity = space.theme.intensity
            grain = space.theme.grain
            profileID = space.profileID
        } else {
            profileID = store.state.defaultProfile.id
            if let preset = SpaceTheme.presets.dropFirst(store.state.spaces.count % SpaceTheme.presets.count).first {
                primary = Color(preset.primary)
            }
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespaces)
        if let spaceID {
            let previousProfile = store.state.space(spaceID)?.profileID
            store.update { state in
                state.updateSpace(spaceID) { space in
                    space.title = name
                    space.icon = icon
                    space.theme = theme
                    if let profileID { space.profileID = profileID }
                }
            }
            if previousProfile != profileID {
                // Tabs must reload in the other profile's context.
                for tab in store.state.space(spaceID)?.allTabs ?? [] { store.discardRuntime(tab.id) }
            }
        } else {
            var created: Space?
            store.update { created = $0.createSpace(title: name, icon: icon, theme: theme, profileID: profileID) }
            if let created { controller.selectSpace(created.id) }
        }
        dismiss()
    }
}
