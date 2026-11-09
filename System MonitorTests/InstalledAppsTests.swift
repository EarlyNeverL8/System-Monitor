import Foundation
import Testing
@testable import System_Monitor

// MARK: - Installed apps & update lookup
struct InstalledAppsTests {
    private func app(source: InstalledApp.Source = .developer, version: String? = "1.9") -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                     bundleID: "com.example.app", version: version, source: source)
    }

    @Test func comparesNumericVersionsWithoutLexicalMistakes() {
        #expect(AppVersion.compare("1.9", "1.10") == .orderedAscending)
        #expect(AppVersion.compare("1.0.0", "1") == .orderedSame)
        #expect(AppVersion.compare("v2.1", "2.0") == .orderedDescending)
        #expect(AppVersion.compare("1.2-beta", "1.2") == nil)
        #expect(AppVersion.compare("latest", "1.2") == nil)
        #expect(AppVersion.compare("", "1") == nil)
    }

    @Test func appStoreResultRequiresExactBundleIDAndMacListing() throws {
        let data = Data(#"""
        {"results":[
          {"bundleId":"com.unrelated.app","kind":"mac-software","version":"99","trackId":1},
          {"bundleId":"com.example.app","kind":"software","version":"99","trackId":2},
          {"bundleId":"com.example.app","kind":"mac-software","version":"1.10","trackId":123}
        ]}
        """#.utf8)
        let result = try UpdateLookup.storeResult(app(source: .appStore), data: data)
        guard case .available(let version, let destination, _, let method) = result else {
            Issue.record("Expected a store update"); return
        }
        #expect(version == "1.10")
        #expect(destination.scheme == "macappstore")
        #expect(destination.absoluteString.hasSuffix("id123"))
        #expect(method == .appStore(trackID: 123))
        let absent = try UpdateLookup.storeResult(app(source: .appStore), data: Data(#"{"results":[]}"#.utf8))
        guard case .unknown = absent else { Issue.record("Missing listing must be unknown"); return }
    }

    @Test func caskMatchingRequiresBundleIDAndFilename() throws {
        let data = Data(#"""
        [{"token":"example","version":"1.10,123","homepage":"https://example.com",
          "artifacts":[{"app":["Example.app"]},{"uninstall":[{"quit":"com.example.app"}]}]}]
        """#.utf8)
        let releases = try CaskRelease.decodeCatalog(data)
        guard case .available(let version, let destination, _, let method) = UpdateLookup.caskResult(app(), releases: releases) else {
            Issue.record("Expected a website update"); return
        }
        #expect(version == "1.10")
        #expect(destination.host == "example.com")
        #expect(method == .homebrew(token: "example"))
        let wrong = InstalledApp(url: app().url, name: "Example", bundleID: "com.other.app",
                                 version: "1", source: .developer)
        guard case .unknown = UpdateLookup.caskResult(wrong, releases: releases) else {
            Issue.record("A name match alone must not identify an app"); return
        }
        guard case .unknown = UpdateLookup.caskResult(app(), releases: releases + releases) else {
            Issue.record("Ambiguous catalogs must not offer an update"); return
        }
    }

    @Test func unknownVersionsAndUnsafeLinksAreNotOffered() throws {
        #expect(UpdateLookup.webURL("javascript:alert(1)") == nil)
        #expect(UpdateLookup.webURL("file:///tmp/update") == nil)
        #expect(UpdateLookup.webURL("https://user:secret@example.com") == nil)
        let link = try #require(URL(string: "https://example.com"))
        let method = UpdateMethod.homebrew(token: "fixture")
        guard case .unknown = UpdateLookup.result(installed: "2.0-beta", latest: "2.0",
                                                  destination: link, source: "fixture", method: method) else {
            Issue.record("Non-release versions must not be guessed"); return
        }
        #expect(UpdateLookup.result(installed: "3", latest: "2", destination: link, source: "fixture", method: method) == .current("fixture"))
    }

    @Test func scansNestedAppsDeduplicatesAndDoesNotIncludeEmbeddedHelpers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func createApp(_ path: String, receipt: Bool = false, bundlePrefix: String = "com.example.") throws {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": bundlePrefix + path, "CFBundleName": path,
                        "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            if receipt {
                let receipts = contents.appendingPathComponent("_MASReceipt")
                try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
                try Data().write(to: receipts.appendingPathComponent("receipt"))
            }
        }
        try createApp("First.app", receipt: true)
        try createApp("Utilities/Second.app")
        try createApp("First.app/Contents/Helpers/Helper.app")
        try createApp("Safari.app", bundlePrefix: "com.apple.")
        try createApp("Pages.app", receipt: true, bundlePrefix: "com.apple.")
        let scan = try await InstalledAppScanner().scan(roots: [root, root.appendingPathComponent("Utilities")])
        #expect(scan.apps.count == 4)
        #expect(scan.apps.contains { $0.url.lastPathComponent == "Safari.app" && $0.source == .system })
        #expect(scan.apps.contains { $0.url.lastPathComponent == "Pages.app" && $0.source == .appStore })
        #expect(scan.apps.contains { $0.url.lastPathComponent == "First.app" && $0.source == .appStore })
        #expect(scan.apps.contains { $0.url.lastPathComponent == "Second.app" && $0.source == .developer })
        #expect(!scan.apps.contains { $0.url.lastPathComponent == "Helper.app" })
    }
}
