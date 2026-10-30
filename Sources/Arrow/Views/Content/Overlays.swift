import ArrowCore
import ArrowKit
import SwiftUI

/// Capture (⇧⌘2): drag to select the area of the page to copy.
struct CaptureOverlay: View {
    let controller: BrowserWindowController
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.25)
                .mask {
                    Rectangle()
                        .overlay(alignment: .topLeading) {
                            if let selection {
                                Rectangle()
                                    .frame(width: selection.width, height: selection.height)
                                    .offset(x: selection.minX, y: selection.minY)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                }
            if let selection {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: selection.width, height: selection.height)
                    .offset(x: selection.minX, y: selection.minY)
                    .shadow(radius: 2)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 28))
                    Text("Drag to capture an area — Esc to cancel")
                        .font(.system(size: 13, weight: .medium))
                    Button("Capture Full Page") {
                        controller.state.isCapturing = false
                        controller.capture(fullPage: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .onChanged { value in
                    start = start ?? value.startLocation
                    current = value.location
                }
                .onEnded { _ in
                    let area = selection
                    start = nil
                    current = nil
                    controller.state.isCapturing = false
                    if let area, area.width > 4, area.height > 4 {
                        controller.capture(area: area)
                    }
                }
        )
    }
}

/// ⌃Tab switcher: recent tabs, the highlighted one opens when ⌃ is released.
struct TabSwitcherOverlay: View {
    let controller: BrowserWindowController
    let tabIDs: [UUID]
    let index: Int
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(tabIDs.enumerated()), id: \.element) { position, id in
                if let tab = store.state.tab(id) {
                    VStack(spacing: 8) {
                        FaviconView(url: tab.url, image: store.tabs[id]?.favicon?.nsImage, size: 32)
                        Text(store.tabs[id]?.displayTitle ?? tab.displayTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 110, height: 96)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(position == index ? palette.accent.opacity(0.35) : Color.clear)
                    )
                    .onTapGesture {
                        controller.state.tabSwitcher?.index = position
                        controller.commitTabSwitcher()
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }
}
