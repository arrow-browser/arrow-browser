import Foundation
import Testing
@testable import ArrowWindows

@MainActor
struct LiveFoldersTests {
    @Test func searchesARepositoryOrAUser() throws {
        let repository = LiveFolders.Source(query: "swiftlang/swift", kind: .pullRequests)
        #expect(repository.title == "swiftlang/swift Pull Requests")
        #expect(try search(repository) == "repo:swiftlang/swift is:open is:pr")
        let user = LiveFolders.Source(query: "octocat", kind: .issues)
        #expect(user.title == "octocat Issues")
        #expect(try search(user) == "involves:octocat is:open is:issue")
    }

    @Test func readsSearchResults() {
        let results = """
        {"total_count": 2, "items": [
          {"title": "Fix the build", "html_url": "https://github.com/swiftlang/swift/pull/1"},
          {"title": "No page"}
        ]}
        """
        let items = LiveFolders.items(Data(results.utf8))
        #expect(items.map(\.title) == ["Fix the build"])
        #expect(items.map(\.url) == ["https://github.com/swiftlang/swift/pull/1"])
        // GitHub's answer to a repository it cannot search.
        #expect(LiveFolders.items(Data(#"{"message": "Validation Failed"}"#.utf8)).isEmpty)
    }

    private func search(_ source: LiveFolders.Source) throws -> String? {
        let url = try #require(source.searchURL)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
    }
}
