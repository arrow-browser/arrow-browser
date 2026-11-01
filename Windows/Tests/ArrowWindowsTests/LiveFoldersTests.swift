import Foundation
import Testing
@testable import ArrowWindows

@MainActor
struct LiveFoldersTests {
    @Test func readsThePullRequestsOfAPage() {
        // As the page's script returns them: [address, title] pairs.
        let result: [String: Any] = ["items": [
            ["https://github.com/swiftlang/swift/pull/1", "Fix the build"],
            ["https://github.com/arrow-browser/arrow-browser/pull/20", "Windows app"],
            ["no title"],
        ]]
        let found = LiveFolders.pullRequests(result)
        #expect(found.map(\.title) == ["Fix the build", "Windows app"])
        #expect(found.map(\.repository) == ["swiftlang/swift", "arrow-browser/arrow-browser"])
        #expect(LiveFolders.pullRequests(["signedOut": true]).isEmpty)
    }
}
