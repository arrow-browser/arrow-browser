import ArrowKit
import Foundation
import Testing
@testable import ArrowCore

@MainActor
struct DownloadManagerTests {
    @Test func newDownloadsDoNotOverwriteExistingFiles() throws {
        let browser = try TestBrowser()
        browser.store.settings.downloadLocation = .folder
        browser.store.settings.downloadFolder = browser.directory.path
        try Data().write(to: browser.directory.appendingPathComponent("report.pdf"))

        let destination = browser.store.downloads.downloadCenter(destinationFor: "report.pdf")
        #expect(destination.url.lastPathComponent == "report (1).pdf")
        #expect(!destination.ask)
    }

    @Test func finishedDownloadsAreListedAndAnnouncedToTheFileManager() throws {
        let browser = try TestBrowser()
        let downloads = browser.store.downloads
        let path = browser.directory.appendingPathComponent("file.zip").path
        var download = Download(id: 7, url: "https://example.com/file.zip", suggestedFileName: "file.zip", fullPath: path,
                                mimeType: "application/zip", receivedBytes: 10, totalBytes: 100, percentComplete: 10,
                                currentSpeed: 0, state: .inProgress)
        downloads.downloadCenter(didUpdate: download)
        #expect(downloads.activeCount == 1)
        #expect(downloads.items.first?.fraction == 0.1)

        download.receivedBytes = 100
        download.state = .complete
        downloads.downloadCenter(didUpdate: download)
        #expect(downloads.activeCount == 0)
        #expect(downloads.recentlyCompleted?.fileName == "file.zip")
        #expect(browser.platform.changedFiles == [URL(fileURLWithPath: path)])

        let item = try #require(downloads.items.first)
        downloads.reveal(item)
        downloads.open(item)
        #expect(browser.platform.revealed == [item.destination])
        #expect(browser.platform.opened == [item.destination])
        downloads.cancel(item)
        #expect((browser.runtime.downloads as? FakeDownloadCenter)?.canceled == [7])
    }
}

@MainActor
struct AdBlockerTests {
    @Test func cachedListsBlockRequestsExceptOnAllowedSites() async throws {
        let browser = try TestBrowser()
        let lists = browser.store.dataDirectory.appendingPathComponent("Blocklists", isDirectory: true)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        try "||ads.example^\n".write(to: lists.appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)
        let filter = try #require(browser.runtime.resourceFilter as? FakeResourceFilter)

        let blocker = browser.store.adBlocker
        blocker.start()
        for _ in 0..<200 where blocker.ruleCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(blocker.ruleCount == 1)
        #expect(filter.blocks("https://ads.example/banner.js", initiator: "https://news.com/"))
        #expect(!filter.blocks("https://cdn.news.com/app.js", initiator: "https://news.com/"))

        blocker.setAllowed(true, site: "https://www.news.com/article")
        #expect(blocker.isAllowed(site: "https://news.com"))
        #expect(!filter.blocks("https://ads.example/banner.js", initiator: "https://news.com/"))
        #expect(filter.blocks("https://ads.example/banner.js", initiator: "https://other.com/"))
    }
}

struct LineBufferTests {
    @Test func splitsChunksIntoLines() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("data: {\"rev".utf8)).isEmpty)
        #expect(buffer.append(Data("ision\":2}\r\n\r\nda".utf8)) == [#"data: {"revision":2}"#, ""])
        #expect(buffer.append(Data("ta: x\n".utf8)) == ["data: x"])
        #expect(buffer.finish() == nil)
        _ = buffer.append(Data("tail".utf8))
        #expect(buffer.finish() == "tail")
    }
}

@MainActor
struct PageImageTests {
    @Test func readsThePixelSizeOfPNGs() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        png.append(Data("IHDR".utf8))
        png.append(contentsOf: [0, 0, 0, 64, 0, 0, 1, 0, 8, 6, 0, 0, 0])
        #expect(PageImage(data: png).pixelSize?.width == 64)
        #expect(PageImage(data: png).pixelSize?.height == 256)
        #expect(PageImage(data: Data("GIF89a".utf8)).pixelSize == nil)
    }
}

struct ParsingTests {
    @Test func readsExtensionIDsFromWebStoreLinks() {
        let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
        #expect(ExtensionManager.extensionID(from: "https://chromewebstore.google.com/detail/ublock-origin/\(id)?hl=en") == id)
        #expect(ExtensionManager.extensionID(from: id) == id)
        #expect(ExtensionManager.extensionID(from: "https://example.com") == nil)
    }

    @Test func readsTidyGroupsInsideCodeFences() {
        let reply = "```json\n{\"groups\":[{\"name\":\"News\",\"tabs\":[2,1]},{\"name\":\"Code\",\"tabs\":[3]}]}\n```"
        #expect(TidyGroups.parse(reply) == [[2, 1], [3]])
        #expect(TidyGroups.parse("no JSON") == nil)
    }
}
