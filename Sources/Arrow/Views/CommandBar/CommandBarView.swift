import ArrowCore
import ArrowKit
import SwiftUI

/// Arc's command bar: a floating search/URL field with tabs, history,
/// suggestions and commands (⌘T, ⌘L).
struct CommandBarOverlay: View {
    @Bindable var model: CommandBarModel
    let controller: BrowserWindowController
    let sidebarWidth: CGFloat
    @Environment(\.palette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.dismissCommandBar() }

                panel
                    .frame(width: width(in: proxy.size))
                    .offset(offset(in: proxy.size))
            }
        }
        .onAppear {
            isFocused = true
            // Focus again once the overlay is in the window.
            DispatchQueue.main.async { isFocused = true }
        }
    }

    // Geometry measured on Arc 1.170, in windows of 1280×820 and 2560×1374 pt.
    private func width(in size: CGSize) -> CGFloat {
        switch model.anchor {
        case .center: min(764, size.width - 80)
        case .sidebar: min(max(sidebarWidth + 340, 560), size.width - 16)
        }
    }

    private func offset(in size: CGSize) -> CGSize {
        switch model.anchor {
        case .center:
            CGSize(width: (size.width - width(in: size)) / 2, height: max(size.height / 2 - 168, 40))
        case .sidebar:
            CGSize(width: 6, height: ArrowWindow.trafficLightCenterY * 2 - 4)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if let site = model.activeSiteSearch {
                    HStack(spacing: 5) {
                        FaviconView(url: "https://\(site.domain)", size: 14)
                        Text(site.name)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                } else {
                    Image(systemName: fieldSymbol)
                        .font(.system(size: 11.5, weight: .bold))
                        .frame(width: 24)
                }
                TextField(model.placeholder, text: $model.text, selection: $model.textSelection)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift), let url = model.instantLinkURL else { return .ignored }
                        controller.state.commandBar = nil
                        controller.open(url, mode: model.mode)
                        return .handled
                    }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                    .onKeyPress(.tab) { model.acceptSiteSearchHint() ? .handled : .ignored }
                    .onKeyPress(.escape) { controller.dismissCommandBar(); return .handled }
                    .onKeyPress(.delete) {
                        if model.text.isEmpty, model.activeSiteSearch != nil {
                            model.clearSiteSearch()
                            return .handled
                        }
                        return .ignored
                    }
                if let hint = model.siteSearchHint {
                    Text("Search \(hint.name)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    KeyCap(label: "Tab")
                } else if model.typedText.isEmpty, model.activeSiteSearch == nil {
                    Button { controller.dismissCommandBar(); (NSApp.delegate as? AppDelegate)?.showKeyboardShortcuts(nil) } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(palette.isDark ? Color(white: 0.24) : .white)
                                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Command Bar Tips")
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .frame(height: 62)

            if !model.items.isEmpty {
                Divider().opacity(0.5)
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                CommandBarRow(item: item, isSelected: index == model.selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { controller.perform(item, from: model) }
                                    .onHover { if $0 { model.selectedIndex = index } }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 440)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.selectedIndex) { _, index in
                        if model.items.indices.contains(index) { reader.scrollTo(model.items[index].id) }
                    }
                }
            }
            if model.mode == .newTab {
                DefaultBrowserBanner()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            // The shadow belongs to the panel only: applied to the whole stack,
            // every row and label would cast one onto the panel.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.isDark ? Color(white: 0.16) : Color(white: 0.976))
                .shadow(color: .black.opacity(0.28), radius: 40, x: 0, y: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// Arc shows the kind of the selected row (history, search…) in the field.
    private var fieldSymbol: String {
        guard !model.typedText.isEmpty, let symbol = model.selectedItem?.symbol else { return "magnifyingglass" }
        return symbol
    }

    private func submit() {
        if let item = model.selectedItem {
            controller.perform(item, from: model)
        } else if !model.text.isEmpty {
            let url = model.activeSiteSearch.map { $0.searchURL(for: model.text) }
                ?? URLInput.resolve(model.text, engine: controller.store.settings.searchEngine)
            controller.state.commandBar = nil
            controller.open(url, mode: model.mode)
        }
    }
}

struct CommandBarRow: View {
    let item: CommandBarItem
    let isSelected: Bool
    /// Little Arrow's launcher lists tabs without "Switch to Tab", with
    /// their domain instead.
    var showsAction = true
    @Environment(\.palette) private var palette

    private var subtitle: String? {
        item.subtitle ?? (showsAction ? nil : item.url.flatMap { URLDisplay.host(of: $0) })
    }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                } else {
                    // Arc sets the selected row's favicon on a white tile.
                    FaviconView(url: item.url ?? "", size: 16)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(isSelected ? 1 : 0)))
                }
            }
            .frame(width: 24)

            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text("— \(subtitle)")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsAction, let action = item.actionLabel {
                Text(action)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .secondary)
                if action == "Switch to Tab" {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? palette.accent : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.white : Color.primary.opacity(0.06))
                        )
                        .padding(.leading, 1)
                }
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.leading, 10)
        .padding(.trailing, 13)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? palette.accent : .clear)
        )
    }
}

/// A key, as drawn in Arc's command bar ("Tab").
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

extension CommandBarModel {
    /// `selectedRange` as the selection of a SwiftUI text field.
    var textSelection: TextSelection? {
        get { selectedRange.map { TextSelection(range: $0) } }
        set {
            switch newValue?.indices {
            case let .selection(range): selectedRange = range
            case let .multiSelection(ranges): selectedRange = ranges.ranges.first
            case nil: selectedRange = nil
            @unknown default: selectedRange = nil
            }
        }
    }
}
