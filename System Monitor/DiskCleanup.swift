import Foundation

// MARK: - File helpers
nonisolated enum FileSizes {
    /// On-disk size of a file, folder or bundle, without following symlinks.
    static func allocatedSize(of url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in scanError = error; return false }
        ) else { throw CleanupError.changedOrProtected }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        if let scanError { throw scanError }
        return total
    }

    /// Like `allocatedSize`, but skips unreadable parts instead of failing.
    static func approximateSize(of url: URL) -> Int64 {
        if let exact = try? allocatedSize(of: url) { return exact }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                        errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            if let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

/// Inode + device, used to confirm an item is still the one the user reviewed.
nonisolated struct FileIdentity: Equatable, Sendable {
    let inode: UInt64
    let device: UInt64

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value else { return nil }
        self.inode = inode
        self.device = device
    }
}

/// A file or folder found by a disk-cleanup scan.
nonisolated struct DiskItem: Identifiable, Sendable, Hashable {
    let url: URL
    let bytes: Int64
    let identity: FileIdentity
    /// The folder the item must still be directly inside when it's removed.
    let parent: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }

    static func == (lhs: DiskItem, rhs: DiskItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    init?(url: URL, bytes: Int64? = nil) {
        guard let identity = FileIdentity(url) else { return nil }
        self.url = url
        self.identity = identity
        self.parent = url.deletingLastPathComponent()
        self.bytes = bytes ?? FileSizes.approximateSize(of: url)
    }

    /// Re-checks the item and removes it: permanently, or by moving it to the Trash.
    func remove(toTrash: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
              FileIdentity(url) == identity else { throw CleanupError.changedOrProtected }
        if toTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Removes items one by one and reports what happened.
    static func remove(_ items: [DiskItem], toTrash: (DiskItem) -> Bool) -> CleanupResult {
        var result = CleanupResult()
        for item in items {
            do {
                try item.remove(toTrash: toTrash(item))
                result.removed.insert(item.url)
            } catch {
                if CleanupService.isPermissionError(error) { result.needsAccess = true }
                result.failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return result
    }
}

// MARK: - System junk
nonisolated enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case appCaches = "App caches"
    case logs = "Logs and crash reports"
    case xcodeBuilds = "Xcode build data"
    case deviceSupport = "Xcode device support"
    case developerCaches = "Developer tool caches"
    case mailDownloads = "Mail attachments cache"
    case deviceBackups = "iPhone and iPad backups"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .appCaches: "Files apps recreate when needed. Caches of running apps and macOS itself are skipped."
        case .logs: "Diagnostic logs and crash reports apps have written."
        case .xcodeBuilds: "DerivedData: Xcode rebuilds it the next time you build."
        case .deviceSupport: "Debug symbols for devices you’ve connected. Xcode downloads them again when needed."
        case .developerCaches: "npm, Gradle and Cargo download caches."
        case .mailDownloads: "Copies of attachments you opened in Mail. The originals stay in your mail."
        case .deviceBackups: "Local backups made by Finder. Moved to the Trash so you can still restore them."
        }
    }

    var symbol: String {
        switch self {
        case .appCaches: "archivebox"
        case .logs: "doc.text.magnifyingglass"
        case .xcodeBuilds: "hammer"
        case .deviceSupport: "iphone.gen3"
        case .developerCaches: "terminal"
        case .mailDownloads: "paperclip"
        case .deviceBackups: "externaldrive.badge.timemachine"
        }
    }

    /// Backups aren't selected by default and go to the Trash rather than being deleted.
    var selectedByDefault: Bool { self != .deviceBackups }
    var movesToTrash: Bool { self == .deviceBackups }

    /// Folders whose children are offered for cleaning, and folders cleaned as a whole.
    func locations(home: URL) -> (childrenOf: [URL], whole: [URL]) {
        let library = home.appendingPathComponent("Library")
        let developer = library.appendingPathComponent("Developer/Xcode")
        switch self {
        case .appCaches: return ([library.appendingPathComponent("Caches")], [])
        case .logs: return ([library.appendingPathComponent("Logs")], [])
        case .xcodeBuilds: return ([developer.appendingPathComponent("DerivedData")], [])
        case .deviceSupport:
            return (["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map {
                developer.appendingPathComponent("\($0) DeviceSupport")
            }, [])
        case .developerCaches:
            return ([], [home.appendingPathComponent(".npm/_cacache"),
                         home.appendingPathComponent(".gradle/caches"),
                         home.appendingPathComponent(".cargo/registry/cache")])
        case .mailDownloads:
            return ([library.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads")], [])
        case .deviceBackups:
            return ([library.appendingPathComponent("Application Support/MobileSync/Backup")], [])
        }
    }
}

nonisolated struct JunkGroup: Identifiable, Sendable {
    let category: JunkCategory
    var items: [DiskItem]
    var id: JunkCategory { category }
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

actor JunkService {
    private let home: URL
    init(home: URL = PermissionCenter.realHomeDirectory) { self.home = home }

    /// Apple's own caches without a com.apple prefix that macOS relies on.
    private static let protectedCacheNames: Set<String> = ["CloudKit", "FamilyCircle", "GeoServices", "Metadata", "PassKit"]

    func scan(runningBundleIDs: Set<String>) throws -> [JunkGroup] {
        var groups: [JunkGroup] = []
        let ownID = Bundle.main.bundleIdentifier
        for category in JunkCategory.allCases {
            try Task.checkCancellation()
            let (parents, wholes) = category.locations(home: home)
            var items: [DiskItem] = []
            for parent in parents {
                let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                for child in children where child.lastPathComponent != ".DS_Store" {
                    try Task.checkCancellation()
                    let name = child.lastPathComponent
                    if category == .appCaches {
                        guard !name.hasPrefix("com.apple."), !Self.protectedCacheNames.contains(name),
                              !runningBundleIDs.contains(name), name != ownID else { continue }
                    }
                    if let item = DiskItem(url: child), item.bytes > 0 { items.append(item) }
                }
            }
            for whole in wholes where FileManager.default.fileExists(atPath: whole.path) {
                if let item = DiskItem(url: whole), item.bytes > 0 { items.append(item) }
            }
            if !items.isEmpty {
                groups.append(JunkGroup(category: category, items: items.sorted { $0.bytes > $1.bytes }))
            }
        }
        return groups
    }

    func remove(_ items: [DiskItem], categories: [URL: JunkCategory]) -> CleanupResult {
        DiskItem.remove(items) { categories[$0.url]?.movesToTrash ?? true }
    }
}

// MARK: - Storage overview & large files
nonisolated struct FolderUsage: Identifiable, Sendable {
    let url: URL
    let bytes: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

nonisolated struct LargeFile: Identifiable, Sendable {
    let item: DiskItem
    let modified: Date?
    /// Bundles such as a Photos library: shown, but only revealed in Finder, never trashed here.
    let isPackage: Bool
    var id: URL { item.url }
}

nonisolated struct StorageScan: Sendable {
    var folders: [FolderUsage] = []
    var largeFiles: [LargeFile] = []
    var unreadable = 0
}

actor StorageScanner {
    private let home: URL
    init(home: URL = PermissionCenter.realHomeDirectory) { self.home = home }

    /// Sizes every top-level folder in your home folder and collects files at least
    /// `threshold` bytes large (outside ~/Library, which System Junk covers).
    func scan(threshold: Int64, progress: @escaping @Sendable (String) -> Void) throws -> StorageScan {
        var result = StorageScan()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let library = home.appendingPathComponent("Library").standardizedFileURL
        let children = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: Array(keys))
        for child in children {
            try Task.checkCancellation()
            progress(child.lastPathComponent)
            guard let values = try? child.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            let listsFiles = child.standardizedFileURL != library
            if values.isDirectory != true {
                let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                result.folders.append(FolderUsage(url: child, bytes: bytes))
                if listsFiles, bytes >= threshold, let item = DiskItem(url: child, bytes: bytes) {
                    result.largeFiles.append(LargeFile(item: item, modified: values.contentModificationDate, isPackage: false))
                }
                continue
            }
            var total: Int64 = 0
            var unreadable = 0
            let enumerator = FileManager.default.enumerator(at: child, includingPropertiesForKeys: Array(keys),
                                                            errorHandler: { _, _ in unreadable += 1; return true })
            while let url = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isPackage == true {
                    // Measure bundles as a whole so they appear as one item.
                    enumerator?.skipDescendants()
                    let bytes = FileSizes.approximateSize(of: url)
                    total += bytes
                    if listsFiles, bytes >= threshold, let item = DiskItem(url: url, bytes: bytes) {
                        result.largeFiles.append(LargeFile(item: item, modified: values.contentModificationDate, isPackage: true))
                    }
                } else if values.isRegularFile == true {
                    let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                    total += bytes
                    if listsFiles, bytes >= threshold, let item = DiskItem(url: url, bytes: bytes) {
                        result.largeFiles.append(LargeFile(item: item, modified: values.contentModificationDate, isPackage: false))
                    }
                }
            }
            result.unreadable += unreadable
            result.folders.append(FolderUsage(url: child, bytes: total))
        }
        result.folders.sort { $0.bytes > $1.bytes }
        result.largeFiles.sort { $0.item.bytes > $1.item.bytes }
        if result.largeFiles.count > 300 { result.largeFiles = Array(result.largeFiles.prefix(300)) }
        return result
    }

    func trash(_ items: [DiskItem]) -> CleanupResult {
        DiskItem.remove(items) { _ in true }
    }
}

// MARK: - Uninstall leftovers
/// Files an app leaves in ~/Library after its bundle is removed: preferences,
/// caches, containers, saved state, launch agents and so on.
nonisolated enum LeftoverFinder {
    /// Folders matched by bundle identifier ("com.example.app", "com.example.app.plist"…).
    static let bundleIDFolders = [
        "Application Support", "Caches", "Containers", "Preferences", "Preferences/ByHost",
        "Saved Application State", "HTTPStorages", "WebKit", "Logs", "LaunchAgents",
        "Application Scripts", "Cookies"
    ]
    /// Folders where apps also use their display name ("Example").
    static let nameFolders = ["Application Support", "Caches", "Logs"]

    static func find(bundleID: String?, appName: String, home: URL, otherBundleIDs: Set<String>) -> [DiskItem] {
        // Apple apps are never uninstalled here; their data is part of macOS.
        if let bundleID, bundleID.hasPrefix("com.apple.") { return [] }
        let library = home.appendingPathComponent("Library")
        var found: [URL] = []
        func children(_ folder: String) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: library.appendingPathComponent(folder),
                                                          includingPropertiesForKeys: nil)) ?? []
        }
        if let bundleID {
            for folder in bundleIDFolders {
                found += children(folder).filter { matches($0.lastPathComponent, bundleID: bundleID, others: otherBundleIDs) }
            }
            // Shared containers are named like "TEAMID.com.example.app" or "group.com.example.app".
            found += children("Group Containers").filter {
                let name = $0.lastPathComponent
                return name.hasSuffix("." + bundleID) || name == bundleID
            }
        }
        if appName.count >= 3 {
            for folder in nameFolders {
                found += children(folder).filter { $0.lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame }
            }
        }
        var seen: Set<URL> = []
        return found.filter { seen.insert($0.standardizedFileURL).inserted }.compactMap { DiskItem(url: $0) }
    }

    /// "com.example.app", "com.example.app.plist", "com.example.app.savedState" or
    /// "com.example.app.helper" — unless that longer ID belongs to another installed app.
    static func matches(_ name: String, bundleID: String, others: Set<String>) -> Bool {
        guard name == bundleID || name.hasPrefix(bundleID + ".") else { return false }
        return !others.contains { other in
            other != bundleID && other.count > bundleID.count && (name == other || name.hasPrefix(other + "."))
        }
    }
}
