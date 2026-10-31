import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// Downloads: a flyout over the sidebar's downloads button, with each
/// file's progress, and a notice when one is done.
extension BrowserWindow {
    func showDownloads(under anchor: FrameworkElement) {
        let downloads = store.downloads
        let flyout = Flyout()
        flyout.shouldConstrainToRootBounds = false
        flyout.placement = .topEdgeAlignedLeft
        let content = StackPanel()
        content.width = 300
        content.spacing = 8
        let header = Grid()
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            header.columnDefinitions.append(column)
        }
        let title = TextBlock()
        title.text = "Downloads"
        title.fontSize = 13
        title.fontWeight = FontWeight(weight: 600)
        title.verticalAlignment = .center
        header.children.append(title)
        let clear = HyperlinkButton()
        clear.content = "Clear Finished"
        clear.fontSize = 12
        clear.click.addHandler { _, _ in
            downloads.clearFinished()
            try? flyout.hide()
        }
        try? Grid.setColumn(clear, 1)
        header.children.append(clear)
        content.children.append(header)
        for item in downloads.items.reversed().prefix(20) {
            content.children.append(downloadRow(item, flyout: flyout))
        }
        if downloads.items.isEmpty {
            let empty = TextBlock()
            empty.text = "No downloads yet."
            empty.opacity = 0.7
            content.children.append(empty)
        }
        flyout.content = content
        try? flyout.showAt(anchor)
    }

    private func downloadRow(_ item: DownloadManager.Item, flyout: Flyout) -> UIElement {
        let downloads = store.downloads
        let row = StackPanel()
        row.spacing = 4
        let name = TextBlock()
        name.text = item.fileName
        name.fontSize = 13
        name.textTrimming = .characterEllipsis
        row.children.append(name)
        let detail = TextBlock()
        detail.fontSize = 11
        detail.opacity = 0.65
        switch item.state {
        case .inProgress, .paused:
            let progress = ProgressBar()
            progress.minimum = 0
            progress.maximum = 1
            progress.value = item.fraction
            progress.isIndeterminate = item.totalBytes <= 0
            row.children.append(progress)
            detail.text = item.state == .paused ? "Paused" : Self.byteCount(item.receivedBytes, of: item.totalBytes)
        case .complete:
            detail.text = Self.byteCount(item.totalBytes > 0 ? item.totalBytes : item.receivedBytes, of: 0)
        default:
            detail.text = "Failed"
        }
        row.children.append(detail)
        let actions = StackPanel()
        actions.orientation = .horizontal
        actions.spacing = 4
        var buttons: [(String, () -> Void)] = []
        switch item.state {
        case .complete:
            buttons = [("Open", { downloads.open(item) }), ("Show in Folder", { downloads.reveal(item) })]
        case .inProgress:
            buttons = [("Pause", { downloads.pause(item) }), ("Cancel", { downloads.cancel(item) })]
        case .paused:
            buttons = [("Resume", { downloads.resume(item) }), ("Cancel", { downloads.cancel(item) })]
        default:
            break
        }
        for (title, action) in buttons {
            let button = HyperlinkButton()
            button.content = title
            button.fontSize = 12
            button.padding = Thickness(left: 4, top: 2, right: 4, bottom: 2)
            button.click.addHandler { _, _ in
                action()
                try? flyout.hide()
            }
            actions.children.append(button)
        }
        row.children.append(actions)
        return row
    }

    private static func byteCount(_ bytes: Int64, of total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: bytes)
        return total > 0 ? "\(done) of \(formatter.string(fromByteCount: total))" : done
    }
}
