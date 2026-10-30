import AppKit
import ArrowCore
import ArrowKit
import SwiftUI

/// Arrow Note: a rich text document opened as a tab.
struct NoteEditorView: View {
    let noteID: UUID
    let tab: WebTab
    @Environment(BrowserStore.self) private var store

    var body: some View {
        RichTextEditor(noteID: noteID, store: store, tab: tab)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct RichTextEditor: NSViewRepresentable {
    let noteID: UUID
    let store: BrowserStore
    let tab: WebTab

    func makeCoordinator() -> Coordinator {
        Coordinator(noteID: noteID, store: store, tab: tab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 64, height: 48)
        textView.delegate = context.coordinator
        if let note = store.note(noteID), !note.body.isEmpty,
           let text = NSAttributedString(rtf: note.body, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(text)
        } else {
            textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.textColor]
        }
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let noteID: UUID
        let store: BrowserStore
        let tab: WebTab
        private var saveTask: Task<Void, Never>?

        init(noteID: UUID, store: BrowserStore, tab: WebTab) {
            self.noteID = noteID
            self.store = store
            self.tab = tab
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let text = textView.attributedString()
            if textView.string.count == 1 {
                textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor]
            }
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                var note = store.note(noteID) ?? Note(id: noteID)
                note.body = text.rtf(from: NSRange(location: 0, length: text.length)) ?? Data()
                let firstLine = text.string.split(separator: "\n").first.map(String.init) ?? ""
                note.title = firstLine.isEmpty ? "Untitled" : String(firstLine.prefix(80))
                note.updatedAt = Date()
                store.saveNote(note)
                tab.title = note.title
                store.syncTabModel(tab)
            }
        }
    }
}

/// Easel: a freeform canvas of captures, text and links.
struct EaselView: View {
    let easelID: UUID
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @State private var dragOffsets: [UUID: CGSize] = [:]
    @State private var tool: Tool = .select
    @State private var color = RGBColor(hex: 0x1C1C1E)
    @State private var currentStroke: [EaselPoint] = []

    enum Tool: String, CaseIterable {
        case select, pen, highlighter, eraser

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            }
        }
    }

    private static let colors: [UInt32] = [0x1C1C1E, 0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x007AFF, 0xAF52DE]

    private var lineWidth: Double { tool == .highlighter ? 14 : 3 }

    var body: some View {
        let easel = store.easel(easelID) ?? Easel(id: easelID)
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            Canvas { context, size in
                let spacing: CGFloat = 24
                for x in stride(from: 0, through: size.width, by: spacing) {
                    for y in stride(from: 0, through: size.height, by: spacing) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.gray.opacity(0.25)))
                    }
                }
            }
            ForEach(easel.items) { item in
                EaselItemView(item: item)
                    .frame(width: item.width, height: item.height)
                    .offset(x: item.x + (dragOffsets[item.id]?.width ?? 0), y: item.y + (dragOffsets[item.id]?.height ?? 0))
                    .gesture(DragGesture()
                        .onChanged { if tool == .select { dragOffsets[item.id] = $0.translation } }
                        .onEnded { value in
                            guard tool == .select else { return }
                            dragOffsets[item.id] = nil
                            update { easel in
                                guard let index = easel.items.firstIndex(where: { $0.id == item.id }) else { return }
                                easel.items[index].x += value.translation.width
                                easel.items[index].y += value.translation.height
                            }
                        })
                    .onTapGesture {
                        if tool == .eraser { update { $0.items.removeAll { $0.id == item.id } } }
                    }
                    .allowsHitTesting(tool == .select || tool == .eraser)
                    .contextMenu {
                        Button("Delete", role: .destructive) { update { $0.items.removeAll { $0.id == item.id } } }
                    }
            }
            // Stroke being drawn.
            if currentStroke.count > 1 {
                StrokeShape(points: currentStroke)
                    .stroke(Color(color).opacity(tool == .highlighter ? 0.4 : 1),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
            }
            if tool == .pen || tool == .highlighter {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { currentStroke.append(EaselPoint(x: $0.location.x, y: $0.location.y)) }
                        .onEnded { _ in finishStroke() })
                    .padding(.top, 64)
            }
            HStack(spacing: 8) {
                TextField("Easel title", text: Binding(get: { easel.title }, set: { title in update { $0.title = title } }))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))
                    .frame(width: 260)
                Spacer()
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        Image(systemName: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 4) {
                    ForEach(Self.colors, id: \.self) { hex in
                        Circle()
                            .fill(Color(RGBColor(hex: hex)))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(color == RGBColor(hex: hex) ? 0.8 : 0), lineWidth: 2))
                            .onTapGesture {
                                color = RGBColor(hex: hex)
                                if tool == .select || tool == .eraser { tool = .pen }
                            }
                    }
                }
                Button { addText() } label: { Label("Text", systemImage: "textformat") }
                Button { captureCurrentTab() } label: { Label("Capture Tab", systemImage: "camera.viewfinder") }
                Button { pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            }
            .padding(16)
        }
    }

    private func finishStroke() {
        defer { currentStroke = [] }
        guard currentStroke.count > 1,
              let item = EaselItem.stroke(currentStroke, color: color, lineWidth: lineWidth,
                                          isHighlighter: tool == .highlighter) else { return }
        update { $0.items.append(item) }
    }

    private func update(_ transform: (inout Easel) -> Void) {
        var easel = store.easel(easelID) ?? Easel(id: easelID)
        transform(&easel)
        easel.updatedAt = Date()
        store.saveEasel(easel)
    }

    private func nextPosition() -> CGPoint {
        let count = store.easel(easelID)?.items.count ?? 0
        return CGPoint(x: 40 + Double(count % 4) * 40, y: 80 + Double(count % 6) * 36)
    }

    private func addText() {
        let point = nextPosition()
        update { $0.items.append(EaselItem(content: .text("Double-click to edit"), x: point.x, y: point.y, width: 240, height: 80)) }
    }

    private func pasteImage() {
        guard let image = NSImage(pasteboard: .general), let data = image.pngData else { return }
        let point = nextPosition()
        let size = image.size.fitting(maxWidth: 420)
        update { $0.items.append(EaselItem(content: .image(data, sourceURL: nil), x: point.x, y: point.y, width: size.width, height: size.height)) }
    }

    private func captureCurrentTab() {
        let candidates = controller.store.state.space(controller.state.selectedSpaceID)?.today.allTabs ?? []
        guard let source = candidates.compactMap({ controller.store.tabs[$0.id] }).first(where: { $0.engine != nil && $0.internalPage == nil }),
              let engine = source.engine else { return }
        Task {
            guard let data = await engine.captureScreenshot(), let image = NSImage(data: data) else { return }
            let point = nextPosition()
            let size = image.size.fitting(maxWidth: 420)
            update { $0.items.append(EaselItem(content: .image(data, sourceURL: source.url), x: point.x, y: point.y,
                                              width: size.width, height: size.height)) }
        }
    }
}

private struct EaselItemView: View {
    let item: EaselItem

    var body: some View {
        switch item.content {
        case let .image(data, _):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
        case let .text(text):
            Text(text)
                .font(.system(size: 16, weight: .medium))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.25)))
        case let .link(url, title):
            Link(destination: URL(string: url) ?? URL(string: "about:blank")!) {
                Label(title, systemImage: "link")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case let .stroke(points, color, lineWidth, isHighlighter):
            StrokeShape(points: points)
                .stroke(Color(color).opacity(isHighlighter ? 0.4 : 1),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .contentShape(StrokeShape(points: points).stroke(lineWidth: max(lineWidth, 10)))
        }
    }
}

/// Smooth path through freehand points.
struct StrokeShape: Shape {
    let points: [EaselPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for (previous, point) in zip(points, points.dropFirst()) {
            // Quadratic curves through midpoints smooth the pointer samples.
            let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: mid, control: CGPoint(x: previous.x, y: previous.y))
        }
        if let last = points.last { path.addLine(to: CGPoint(x: last.x, y: last.y)) }
        return path
    }
}

/// arrow://shortcuts — the keyboard shortcuts of the menu bar.
struct ShortcutsPageView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Keyboard Shortcuts")
                    .font(.largeTitle.weight(.bold))
                ForEach(sections(), id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.title3.weight(.semibold))
                        ForEach(section.items, id: \.0) { title, shortcut in
                            HStack {
                                Text(title)
                                Spacer()
                                Text(shortcut)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                            }
                        }
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private struct Section {
        let title: String
        let items: [(String, String)]
    }

    private func sections() -> [Section] {
        guard let menu = NSApp.mainMenu else { return [] }
        return menu.items.compactMap { item in
            guard let submenu = item.submenu else { return nil }
            let entries = submenu.items.compactMap { entry -> (String, String)? in
                guard !entry.keyEquivalent.isEmpty, !entry.isSeparatorItem else { return nil }
                return (entry.title, Self.describe(entry))
            }
            return entries.isEmpty ? nil : Section(title: submenu.title, items: entries)
        }
    }

    private static func describe(_ item: NSMenuItem) -> String {
        var text = ""
        let flags = item.keyEquivalentModifierMask
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let key: String = switch item.keyEquivalent {
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓"
        case "\t": "⇥"
        case "\u{1b}": "⎋"
        default: item.keyEquivalent.uppercased()
        }
        return text + key
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension CGSize {
    func fitting(maxWidth: CGFloat) -> CGSize {
        guard width > maxWidth, width > 0 else { return self }
        return CGSize(width: maxWidth, height: height * maxWidth / width)
    }
}
