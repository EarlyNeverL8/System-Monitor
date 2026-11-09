import Foundation
import Testing
@testable import System_Monitor

// MARK: - Per-app network & update feeds
struct NetworkAndUpdateFeedTests {
    @Test func nettopParsesOnlyTheLastDeltaSample() {
        let csv = """
        ,bytes_in,bytes_out,
        configd.1,924,1134,
        ,bytes_in,bytes_out,
        configd.1,0,0,
        Google Chrome H.999999,2000,500,
        broken line
        """
        let traffic = NetworkUsageSampler.parse(csv)
        #expect(traffic.count == 1)                    // idle and malformed rows are dropped
        #expect(traffic.first?.pid == 999999)
        #expect(traffic.first?.download == 2000)
        #expect(traffic.first?.upload == 500)
        #expect(traffic.first?.name == "Google Chrome H")  // no such pid, so nettop's name is kept
    }

    @Test func appcastPicksNewestStableRelease() throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <link>https://example.com</link>
          <item><enclosure url="https://example.com/1.9.dmg" sparkle:shortVersionString="1.9" sparkle:version="190"/></item>
          <item><sparkle:shortVersionString>2.1</sparkle:shortVersionString>
                <link>https://example.com/download</link></item>
          <item><sparkle:channel>beta</sparkle:channel>
                <enclosure url="https://example.com/3.0b.dmg" sparkle:shortVersionString="3.0"/></item>
        </channel></rss>
        """
        let release = try #require(Appcast.latestRelease(in: Data(feed.utf8)))
        #expect(release.version == "2.1")
        #expect(release.download?.absoluteString == "https://example.com/download")
        #expect(Appcast.latestRelease(in: Data("not xml".utf8)) == nil)
    }

    @Test func appleBinariesAreRecognisedAsSignedByApple() throws {
        let signer = try #require(CodeSigner.read(atPath: "/bin/ls"))
        #expect(signer.isApple)
        #expect(CodeSigner.read(atPath: "/no/such/program") == nil)
    }

    @Test @MainActor func appStoreSandboxRealHomeAndPublicAPIs() {
        let realHome = PermissionCenter.realHomeDirectory.path
        #expect(!realHome.contains("/Library/Containers/"))
        #expect(HungAppDetector.isAvailable == false)
    }
}

// MARK: - Disk cleanup
struct DiskCleanupTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ path: String, in home: URL, bytes: Int = 4096) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func leftoverMatchingRespectsOtherInstalledApps() {
        #expect(LeftoverFinder.matches("com.example.app.plist", bundleID: "com.example.app", others: []))
        #expect(LeftoverFinder.matches("com.example.app", bundleID: "com.example.app", others: []))
        #expect(!LeftoverFinder.matches("com.example.application", bundleID: "com.example.app", others: []))
        // "com.example.app.pro" belongs to another installed app, so it's kept.
        #expect(!LeftoverFinder.matches("com.example.app.pro.plist", bundleID: "com.example.app",
                                        others: ["com.example.app.pro"]))
    }

    @Test func findsLeftoversByBundleIDAndName() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Library/Preferences/com.example.app.plist", in: home)
        try write("Library/Caches/com.example.app/cache.db", in: home)
        try write("Library/Application Support/Example/data", in: home)
        try write("Library/Group Containers/ABCDE12345.com.example.app/shared", in: home)
        try write("Library/Preferences/com.other.app.plist", in: home)

        let found = LeftoverFinder.find(bundleID: "com.example.app", appName: "Example", home: home, otherBundleIDs: [])
        #expect(Set(found.map(\.name)) == ["com.example.app.plist", "com.example.app", "Example",
                                           "ABCDE12345.com.example.app"])
        #expect(LeftoverFinder.find(bundleID: "com.apple.Safari", appName: "Safari", home: home, otherBundleIDs: []).isEmpty)
    }

    @Test func junkScanSkipsAppleAndRunningAppCaches() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Library/Caches/com.example.tool/blob", in: home)
        try write("Library/Caches/com.apple.Safari/blob", in: home)
        try write("Library/Caches/com.running.app/blob", in: home)
        try write("Library/Developer/Xcode/DerivedData/MyApp-abc/Build", in: home)

        let groups = try await JunkService(home: home).scan(runningBundleIDs: ["com.running.app"])
        let caches = groups.first { $0.category == .appCaches }?.items.map(\.name)
        #expect(caches == ["com.example.tool"])
        #expect(groups.first { $0.category == .xcodeBuilds }?.items.map(\.name) == ["MyApp-abc"])
    }

    @Test func diskItemRefusesReplacedFiles() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("big.mov", in: home)
        let item = try #require(DiskItem(url: home.appendingPathComponent("big.mov")))
        // Replace the file after the scan: removal must be refused.
        try FileManager.default.removeItem(at: item.url)
        try write("big.mov", in: home)
        #expect(throws: CleanupError.self) { try item.remove(toTrash: false) }
        #expect(FileManager.default.fileExists(atPath: item.url.path))

        let fresh = try #require(DiskItem(url: item.url))
        try fresh.remove(toTrash: false)
        #expect(!FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test func storageScanSizesFoldersAndListsLargeFiles() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Movies/clip.mov", in: home, bytes: 2_000_000)
        try write("Documents/note.txt", in: home, bytes: 10)
        try write("Library/Caches/huge.bin", in: home, bytes: 3_000_000)

        let scan = try await StorageScanner(home: home).scan(threshold: 1_000_000) { _ in }
        #expect(scan.largeFiles.map(\.item.name) == ["clip.mov"])     // ~/Library is excluded
        #expect(scan.folders.first?.name == "Library")
        #expect(scan.folders.contains { $0.name == "Movies" && $0.bytes >= 2_000_000 })
    }
}

// MARK: - History
struct HistoryTests {
    @Test func averagesIgnoreMissingReadings() throws {
        let date = Date()
        let samples = [
            ReadingSample(date: date, cpuUsage: 10, memoryUsage: 4, diskSpaceAvailable: nil,
                          download: nil, upload: 1, gpuUsage: nil),
            ReadingSample(date: date.addingTimeInterval(1), cpuUsage: 30, memoryUsage: nil, diskSpaceAvailable: nil,
                          download: nil, upload: 3, gpuUsage: nil)
        ]
        let average = try #require(ReadingSample.average(samples))
        #expect(average.date == date)
        #expect(average.cpuUsage == 20)
        #expect(average.memoryUsage == 4)
        #expect(average.download == nil)
        #expect(average.upload == 2)
    }
}
