import Foundation

// MARK: - Installed apps
nonisolated struct InstalledApp: Identifiable, Sendable {
    enum Source: String, Sendable {
        case appStore = "App Store"
        case developer = "Website / other"
        case system = "Apple"
    }

    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let source: Source
    /// The app's Sparkle update feed (SUFeedURL), if it publishes one.
    var feedURL: URL? = nil
    var id: URL { url }
}

nonisolated struct InstalledAppScan: Sendable {
    var apps: [InstalledApp] = []
    var inaccessibleFolders: [String] = []
}

// MARK: - App scanner
/// Enumerates application folders without descending into app bundles.
actor InstalledAppScanner {
    nonisolated static func isSystemApplication(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == "/System" || path.hasPrefix("/System/")
    }

    /// Re-reads an app's version from disk (used after an update installs).
    nonisolated static func version(at url: URL) -> String? {
        (try? infoPlist(at: url)).flatMap(version(in:))
    }

    nonisolated private static func infoPlist(at url: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    nonisolated private static func version(in info: [String: Any]) -> String? {
        info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
    }

    func scan(roots: [URL]) throws -> InstalledAppScan {
        var result = InstalledAppScan()
        var seen: Set<URL> = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for root in Set(roots.map { $0.standardizedFileURL }) {
            try Task.checkCancellation()
            guard !Self.isSystemApplication(root), FileManager.default.fileExists(atPath: root.path) else { continue }
            var inaccessible: [String] = []
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in inaccessible.append(url.path); return true }
            ) else {
                result.inaccessibleFolders.append(root.path)
                continue
            }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard !Self.isSystemApplication(resolved), seen.insert(resolved).inserted else { continue }
                do {
                    guard let info = try Self.infoPlist(at: resolved) else { continue }
                    // /System apps are skipped above, so Apple's own apps (Safari etc.)
                    // are recognised by bundle ID. App Store receipts take precedence,
                    // so Apple apps installed from the store (Pages, Xcode) stay .appStore.
                    let source: InstalledApp.Source
                    let bundleID = info["CFBundleIdentifier"] as? String
                    if FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
                        source = .appStore
                    } else if bundleID?.hasPrefix("com.apple.") == true {
                        source = .system
                    } else {
                        source = .developer
                    }
                    result.apps.append(InstalledApp(
                        url: resolved,
                        name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                            ?? resolved.deletingPathExtension().lastPathComponent,
                        bundleID: bundleID,
                        version: Self.version(in: info),
                        source: source,
                        feedURL: (info["SUFeedURL"] as? String).flatMap(UpdateLookup.webURL)
                    ))
                } catch {
                    result.inaccessibleFolders.append(resolved.path)
                }
            }
            result.inaccessibleFolders.append(contentsOf: inaccessible)
        }
        result.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
}

// MARK: - Update state
/// How an available update gets installed automatically.
nonisolated enum UpdateMethod: Equatable, Sendable {
    case homebrew(token: String)          // `brew upgrade --cask <token>`
    case appStore(trackID: Int)           // `mas upgrade <trackID>`
    case manual                           // open the developer's download
}

nonisolated enum AppUpdateState: Equatable, Sendable {
    case notChecked
    case checking
    case current(String)
    case available(version: String, destination: URL, source: String, method: UpdateMethod)
    case updating(String)                              // latest installer output line
    case updated(String)                               // new installed version
    case updateFailed(String, destination: URL)        // offers the download page instead
    case unknown(String)
    case failed(String)

    var label: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking…"
        case .current: "Up to date"
        case .available(let version, _, _, _): "Version \(version) available"
        case .updating: "Updating…"
        case .updated(let version): "Updated to \(version)"
        case .updateFailed: "Update failed"
        case .unknown: "Unknown"
        case .failed: "Check failed"
        }
    }

    var detail: String {
        switch self {
        case .notChecked: "Choose Check for Updates to look online."
        case .checking: "Looking up the installed application."
        case .current(let source): "No newer version found in \(source)."
        case .available(_, _, let source, .manual): "Source: \(source). Download opens from the developer."
        case .available(_, _, let source, _): "Source: \(source). Installs automatically when you choose Update."
        case .updating(let line): line
        case .updated: "Installed successfully."
        case .updateFailed(let reason, _): reason
        case .unknown(let reason), .failed(let reason): reason
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Available updates System Monitor can install by itself (not just open a download for).
    var isAutomaticUpdate: Bool {
        if case .available(_, _, _, let method) = self { return method != .manual }
        return false
    }
}

// MARK: - Version comparison
nonisolated enum AppVersion {
    /// Only compare plain release versions. Dates, build labels and prerelease
    /// strings are not comparable reliably across independent catalogs.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func components(_ value: String) -> [Int]? {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("v") { text.removeFirst() }
            guard text.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
            let parts = text.split(separator: ".").map { Int($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - Homebrew catalog
/// One cask from formulae.brew.sh: its app filenames and bundle IDs identify installed apps.
nonisolated struct CaskRelease: Sendable {
    let token: String
    let version: String
    let homepage: URL
    let appFiles: Set<String>
    let bundleIDs: Set<String>

    static func decodeCatalog(_ data: Data) throws -> [CaskRelease] {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return records.compactMap { record in
            guard record["disabled"] as? Bool != true,
                  let token = record["token"] as? String, !token.contains("@"),
                  let version = record["version"] as? String,
                  let address = record["homepage"] as? String,
                  let homepage = UpdateLookup.webURL(address),
                  let artifacts = record["artifacts"] as? [[String: Any]] else { return nil }
            var appFiles: Set<String> = []
            var bundleIDs: Set<String> = []
            for artifact in artifacts {
                if let app = artifact["app"] as? [Any] {
                    for value in app {
                        if let name = value as? String {
                            appFiles.insert(URL(fileURLWithPath: name).lastPathComponent.lowercased())
                        }
                        if let target = (value as? [String: Any])?["target"] as? String {
                            appFiles.insert(URL(fileURLWithPath: target).lastPathComponent.lowercased())
                        }
                    }
                }
                if let uninstall = artifact["uninstall"] as? [[String: Any]] {
                    for entry in uninstall {
                        if let quit = entry["quit"] as? [String] { bundleIDs.formUnion(quit) }
                        if let quit = entry["quit"] as? String { bundleIDs.insert(quit) }
                    }
                }
            }
            return CaskRelease(token: token, version: version, homepage: homepage,
                               appFiles: appFiles, bundleIDs: bundleIDs)
        }
    }
}

// MARK: - Update lookup
/// Looks up the latest published version in the Mac App Store or Homebrew catalog.
actor UpdateLookup {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func catalog() async throws -> [CaskRelease] {
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json") else { throw URLError(.badURL) }
        return try CaskRelease.decodeCatalog(await fetch(url))
    }

    func checkStore(_ app: InstalledApp, country: String) async throws -> AppUpdateState {
        guard let bundleID = app.bundleID else { return .unknown("The app has no bundle identifier.") }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: country)
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try Self.storeResult(app, data: await fetch(url))
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    nonisolated static func storeResult(_ app: InstalledApp, data: Data) throws -> AppUpdateState {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["results"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        guard let record = records.first(where: {
            ($0["bundleId"] as? String) == app.bundleID && ($0["kind"] as? String) == "mac-software"
        }), let latest = record["version"] as? String,
              let trackID = record["trackId"] as? Int,
              let destination = URL(string: "macappstore://itunes.apple.com/app/id\(trackID)") else {
            return .unknown("No matching Mac App Store listing in this region.")
        }
        return result(installed: app.version, latest: latest, destination: destination,
                      source: "Mac App Store", method: .appStore(trackID: trackID))
    }

    /// Reads the app's Sparkle appcast and compares its newest release with the installed version.
    func checkSparkle(_ app: InstalledApp) async throws -> AppUpdateState {
        guard let feed = app.feedURL else { return .unknown("The app doesn’t publish an update feed.") }
        guard let latest = Appcast.latestRelease(in: try await fetch(feed)) else {
            return .unknown("The developer’s update feed has no comparable release.")
        }
        return Self.result(installed: app.version, latest: latest.version, destination: latest.download ?? feed,
                           source: "Developer’s update feed", method: .manual)
    }

    nonisolated static func caskResult(_ app: InstalledApp, releases: [CaskRelease]) -> AppUpdateState {
        guard let bundleID = app.bundleID else { return .unknown("The app has no bundle identifier.") }
        // Require BOTH the app-bundle filename and an exact bundle ID from
        // Homebrew's uninstall metadata, avoiding guesses based on display names.
        let matches = releases.filter {
            $0.appFiles.contains(app.url.lastPathComponent.lowercased()) && $0.bundleIDs.contains(bundleID)
        }
        guard matches.count == 1, let release = matches.first else {
            return .unknown("No unique bundle-ID match in the Homebrew catalog. Use the app’s own updater.")
        }
        let latest = String(release.version.split(separator: ",").first ?? "")
        return result(installed: app.version, latest: latest, destination: release.homepage,
                      source: "Homebrew catalog", method: .homebrew(token: release.token))
    }

    /// Offers an update only when both versions are plain numbers and the published one is newer.
    nonisolated static func result(installed: String?, latest: String, destination: URL, source: String,
                                   method: UpdateMethod) -> AppUpdateState {
        guard let installed, let comparison = AppVersion.compare(installed, latest) else {
            return .unknown("The installed and published versions cannot be compared reliably.")
        }
        return comparison == .orderedAscending
            ? .available(version: latest, destination: destination, source: source, method: method)
            : .current(source)
    }

    nonisolated static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

// MARK: - Sparkle appcasts
/// Parses Sparkle update feeds (RSS with sparkle: version attributes).
nonisolated enum Appcast {
    struct Release: Equatable {
        let version: String
        let download: URL?
    }

    /// The highest stable release in the feed. Beta-channel items are ignored.
    static func latestRelease(in data: Data) -> Release? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let releases = delegate.items.compactMap { item -> Release? in
            guard item.channel == nil, let version = item.shortVersion else { return nil }
            let download = (item.link ?? delegate.channelLink).flatMap(UpdateLookup.webURL)
                ?? item.enclosure.flatMap(UpdateLookup.webURL)
            return Release(version: version, download: download)
        }
        return releases.max { lhs, rhs in AppVersion.compare(lhs.version, rhs.version) == .orderedAscending }
    }
}

private nonisolated final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var shortVersion: String?
        var link: String?
        var enclosure: String?
        var channel: String?
    }

    var items: [Item] = []
    var channelLink: String?
    private var current: Item?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "item": current = Item()
        case "enclosure":
            current?.enclosure = attributes["url"]
            if let short = attributes["sparkle:shortVersionString"] { current?.shortVersion = short }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "item":
            if let current { items.append(current) }
            current = nil
        case "sparkle:shortVersionString": current?.shortVersion = value
        case "sparkle:channel": current?.channel = value
        case "link":
            if current != nil { current?.link = value } else if channelLink == nil { channelLink = value }
        default: break
        }
        text = ""
    }
}
