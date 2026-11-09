import Foundation
import SQLite3

// MARK: - Supported browsers
/// Where each browser keeps its profile data, relative to ~/Library.
nonisolated struct BrowserDefinition: Identifiable, Sendable {
    enum Engine: Sendable {
        case safari
        case chromium(dataFolder: String)       // Application Support/<folder>
        case firefox
    }

    let id: String                              // bundle identifier
    let name: String
    let engine: Engine

    static let supported: [BrowserDefinition] = [
        .init(id: "com.apple.Safari", name: "Safari", engine: .safari),
        .init(id: "com.google.Chrome", name: "Google Chrome", engine: .chromium(dataFolder: "Google/Chrome")),
        .init(id: "com.microsoft.edgemac", name: "Microsoft Edge", engine: .chromium(dataFolder: "Microsoft Edge")),
        .init(id: "com.brave.Browser", name: "Brave", engine: .chromium(dataFolder: "BraveSoftware/Brave-Browser")),
        .init(id: "org.mozilla.firefox", name: "Firefox", engine: .firefox),
        .init(id: "com.operasoftware.Opera", name: "Opera", engine: .chromium(dataFolder: "com.operasoftware.Opera")),
        .init(id: "com.vivaldi.Vivaldi", name: "Vivaldi", engine: .chromium(dataFolder: "Vivaldi")),
        .init(id: "company.thebrowser.Browser", name: "Arc", engine: .chromium(dataFolder: "Arc/User Data"))
    ]
}

nonisolated enum BrowserData: String, Sendable {
    case history = "History"
    case cookies = "Cookies"
}

// MARK: - Browser cleaner
/// Clears history or cookies directly in each browser profile's databases.
/// The browser must be closed first so its databases aren't in use.
/// Bookmarks, passwords, downloads lists and settings are left untouched.
actor BrowserCleaner {
    private let library: URL

    init(home: URL = PermissionCenter.realHomeDirectory) {
        library = home.appendingPathComponent("Library")
    }

    struct Outcome: Sendable {
        var profiles = 0
        var errors: [String] = []
    }

    func clear(_ data: BrowserData, in browser: BrowserDefinition) -> Outcome {
        switch browser.engine {
        case .safari: clearSafari(data)
        case .chromium(let folder): clearChromium(data, base: library.appendingPathComponent("Application Support/\(folder)"))
        case .firefox: clearFirefox(data)
        }
    }

    // MARK: Safari
    private func clearSafari(_ data: BrowserData) -> Outcome {
        var outcome = Outcome()
        switch data {
        case .history:
            run(["DELETE FROM history_visits", "DELETE FROM history_items"],
                on: library.appendingPathComponent("Safari/History.db"), outcome: &outcome)
        case .cookies:
            // Safari keeps cookies in binary files; it recreates them on next launch.
            let files = [library.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                         library.appendingPathComponent("Cookies/Cookies.binarycookies")]
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                do {
                    try FileManager.default.removeItem(at: file)
                    outcome.profiles = 1
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            }
        }
        return outcome
    }

    // MARK: Chrome, Edge, Brave, Opera, Vivaldi, Arc
    private func clearChromium(_ data: BrowserData, base: URL) -> Outcome {
        var outcome = Outcome()
        for profile in chromiumProfiles(in: base) {
            switch data {
            case .history:
                // Clears browsing history but keeps the downloads list.
                run(["DELETE FROM visits", "DELETE FROM visit_source", "DELETE FROM urls",
                     "DELETE FROM keyword_search_terms", "DELETE FROM segment_usage", "DELETE FROM segments",
                     "DELETE FROM clusters_and_visits", "DELETE FROM clusters", "DELETE FROM content_annotations",
                     "DELETE FROM context_annotations"],
                    on: profile.appendingPathComponent("History"), outcome: &outcome)
                // Side files that cache visited URLs for the address bar.
                for name in ["Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"] {
                    try? FileManager.default.removeItem(at: profile.appendingPathComponent(name))
                }
            case .cookies:
                // Newer versions keep cookies under Network/; older ones in the profile root.
                for path in ["Network/Cookies", "Cookies"] {
                    run(["DELETE FROM cookies"], on: profile.appendingPathComponent(path), outcome: &outcome)
                }
            }
        }
        return outcome
    }

    /// "Default", "Profile 1"… plus the base folder itself (Opera stores its profile there).
    private func chromiumProfiles(in base: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return ([base] + children).filter { folder in
            ["History", "Cookies", "Network/Cookies"].contains {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        }
    }

    // MARK: Firefox
    private func clearFirefox(_ data: BrowserData) -> Outcome {
        var outcome = Outcome()
        let profiles = library.appendingPathComponent("Application Support/Firefox/Profiles")
        let folders = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
        for profile in folders {
            switch data {
            case .history:
                // Remove visits, then pages that aren't bookmarked (bookmarks share the table).
                run(["DELETE FROM moz_historyvisits", "DELETE FROM moz_inputhistory",
                     "DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)",
                     "UPDATE moz_places SET visit_count = 0, last_visit_date = NULL"],
                    on: profile.appendingPathComponent("places.sqlite"), outcome: &outcome)
            case .cookies:
                run(["DELETE FROM moz_cookies"], on: profile.appendingPathComponent("cookies.sqlite"), outcome: &outcome)
            }
        }
        return outcome
    }

    // MARK: SQLite
    /// Runs statements against a database if it exists, then VACUUMs so deleted rows
    /// are really gone from disk. Missing tables (older browser versions) are skipped.
    private func run(_ statements: [String], on database: URL, outcome: inout Outcome) {
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            outcome.errors.append("\(database.lastPathComponent): couldn’t open (Full Disk Access may be off)")
            sqlite3_close(handle)
            return
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 3000)
        for statement in statements + ["VACUUM"] {
            guard sqlite3_exec(handle, statement, nil, nil, nil) != SQLITE_OK else { continue }
            let message = String(cString: sqlite3_errmsg(handle))
            if message.hasPrefix("no such table") { continue }
            outcome.errors.append("\(database.lastPathComponent): \(message)")
            return
        }
        outcome.profiles += 1
    }
}
