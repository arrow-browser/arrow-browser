import AppKit
import ArrowKit
import SwiftUI

/// View ▸ Cast: the devices found on the network, in a popover at the top
/// right of the window, like Chromium's Cast dialog.
@MainActor
final class CastPopoverController: NSObject, NSPopoverDelegate {
    private static var current: CastPopoverController?
    private let popover = NSPopover()

    static func show(from controller: BrowserWindowController) {
        current?.popover.close()
        guard let contentView = controller.window?.contentView else { return }
        let tab = controller.selectedTab
        let profileID = tab?.profileID ?? controller.selectedSpace?.profileID ?? controller.store.state.defaultProfile.id
        CastController.shared.startDiscovery(context: controller.store.requestContext(for: profileID))

        let popup = CastPopoverController(tab: tab)
        current = popup
        let top: CGFloat = 12
        let y = contentView.isFlipped ? top : contentView.bounds.height - top - 24
        let anchor = NSRect(x: contentView.bounds.width - 52, y: y, width: 24, height: 24)
        popup.popover.show(relativeTo: anchor, of: contentView, preferredEdge: contentView.isFlipped ? .maxY : .minY)
    }

    private init(tab: WebTab?) {
        super.init()
        popover.contentViewController = NSHostingController(rootView: CastView(tab: tab))
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) {
        CastController.shared.stopDiscovery()
        if Self.current === self { Self.current = nil }
    }
}

struct CastView: View {
    let tab: WebTab?
    @State private var cast = CastController.shared
    @State private var media: Result<CastMedia, CastMediaError>?
    @State private var searchedLong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cast").font(.system(size: 13, weight: .semibold))
                subtitle
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if cast.sinks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 2) {
                    ForEach(cast.sinks) { sink in
                        CastSinkRow(sink: sink, media: try? media?.get(), tab: tab)
                    }
                }
                .padding(6)
            }

            if let error = cast.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 320)
        .task {
            media = await tab?.castableMedia() ?? .failure(CastMediaError(description: "Open a page with a video to cast it."))
            try? await Task.sleep(for: .seconds(6))
            searchedLong = true
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch media {
        case nil: Text("Looking for media on this page…")
        case let .success(media)?: Text(media.title)
        case let .failure(error)?: Text(error.description)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchedLong {
                Text("No devices found").font(.system(size: 12, weight: .medium))
                Text("Cast devices must be on the same network as this Mac, and Arrow must be allowed to find devices in System Settings ▸ Privacy & Security ▸ Local Network.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct CastSinkRow: View {
    let sink: CEFMediaSink
    let media: CastMedia?
    let tab: WebTab?
    @State private var cast = CastController.shared
    @State private var isHovered = false

    private var isCasting: Bool { cast.castingSinkID == sink.id }
    private var isConnecting: Bool { cast.status == .connecting(sinkID: sink.id) }

    private var symbol: String {
        switch sink.kind {
        case .tv, .other: "tv"
        case .speaker: "hifispeaker"
        case .speakerGroup: "hifispeaker.2"
        }
    }

    private var status: String {
        if isConnecting { return "Connecting…" }
        guard isCasting else { return "Available" }
        return switch cast.playerState {
        case "PLAYING": "Playing \(cast.media?.title ?? "")"
        case "PAUSED": "Paused"
        case "BUFFERING": "Loading…"
        default: "Casting"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(isCasting ? Color.accentColor : .primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(sink.name).font(.system(size: 13)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isCasting {
                if cast.playerState == "PLAYING" || cast.playerState == "PAUSED" {
                    Button { cast.togglePlayback() } label: {
                        Image(systemName: cast.playerState == "PAUSED" ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(cast.playerState == "PAUSED" ? "Play" : "Pause")
                }
                Button("Stop") { cast.stop() }
                    .controlSize(.small)
            } else if isConnecting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovered && !isCasting ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !isCasting, !isConnecting, let media else { return }
            Task { await cast.cast(media, to: sink, from: tab) }
        }
        .opacity(media == nil && !isCasting ? 0.5 : 1)
    }
}
