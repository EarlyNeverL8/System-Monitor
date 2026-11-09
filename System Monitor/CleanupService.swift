import Foundation

// MARK: - Cleanup sections
/// The sidebar's CLEANUP entries.
nonisolated enum CleanupSection: String, CaseIterable, Identifiable, Sendable {
    case recentFiles = "Recent Files"
    case trash = "Trash"
    case junk = "System Junk"
    case storage = "Storage"
    case browsers = "Browsers"
    case applications = "Applications"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .recentFiles: "doc.badge.clock"
        case .trash: "trash"
        case .junk: "sparkles"
        case .storage: "chart.pie"
        case .browsers: "globe"
        case .applications: "square.stack.3d.up"
        }
    }
}

// MARK: - Scan results
/// A file or bundle found by a scan. Inode and device let removal confirm it's
/// still the same item that the user reviewed.
nonisolated struct CleanupItem: Identifiable, Sendable {
    let url: URL
    let bytes: Int64
    let modified: Date
    let inode: UInt64
    let device: UInt64
    let section: CleanupSection
    let bundleIdentifier: String?
    let version: String?
    var name: String { url.lastPathComponent }
    var id: URL { url }
}

nonisolated struct CleanupScan: Sendable {
    var items: [CleanupItem] = []
    var unreadableCount = 0
}

nonisolated struct CleanupResult: Sendable {
    var removed: Set<URL> = []
    var failures: [String] = []
    /// Set when at least one removal failed because macOS denied write access.
    var needsAccess = false
}

nonisolated enum CleanupError: LocalizedError {
    case changedOrProtected
    case runningApplication
    case wrongFolder

    var errorDescription: String? {
        switch self {
        case .changedOrProtected: "This item changed since the scan or is protected. Scan again."
        case .runningApplication: "Quit this application before removing it."
        case .wrongFolder: "This folder can’t be cleaned here."
        }
    }
}

// MARK: - Cleanup service
/// Scans and removes items in the user's Trash or an Applications folder. All
/// filesystem work runs off the main actor; symlinks and /System are never touched.
actor CleanupService {
    let homeURL: URL

    init(homeURL: URL) {
        self.homeURL = homeURL.resolvingSymlinksInPath()
    }

    /// Only the home Trash and the Applications folders may be cleaned.
    func validateFolder(_ folder: URL, section: CleanupSection) throws {
        let root = Self.canonicalPath(folder)
        let allowed: [URL] = switch section {
        case .trash: [homeURL.appendingPathComponent(".Trash")]
        case .applications: [URL(fileURLWithPath: "/Applications"), homeURL.appendingPathComponent("Applications")]
        case .recentFiles, .junk, .storage, .browsers: []
        }
        guard allowed.map(Self.canonicalPath).contains(root) else { throw CleanupError.wrongFolder }
    }

    // MARK: Scanning
    func scan(folder: URL, section: CleanupSection) throws -> CleanupScan {
        try validateFolder(folder, section: section)
        let manager = FileManager.default
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        // Trash keeps hidden files (e.g. ".config" folders users deleted), so include them.
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                       options: section == .trash ? [] : [.skipsHiddenFiles])
        var result = CleanupScan()
        for url in children where url.lastPathComponent != ".DS_Store" {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true, !isProtected(url) else { continue }
                if section == .applications {
                    guard values.isDirectory == true, url.pathExtension.lowercased() == "app" else { continue }
                }
                let attributes = try manager.attributesOfItem(atPath: url.path)
                let bundle = url.pathExtension.lowercased() == "app" ? Bundle(url: url) : nil
                let bytes = values.isDirectory == true ? try FileSizes.allocatedSize(of: url) : Int64(values.fileSize ?? 0)
                result.items.append(CleanupItem(
                    url: url, bytes: bytes, modified: values.contentModificationDate ?? .distantPast,
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                    section: section, bundleIdentifier: bundle?.bundleIdentifier,
                    version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.unreadableCount += 1
            }
        }
        // Trash: newest first, like Finder's "Date Added". Apps: alphabetical.
        result.items.sort {
            section == .trash ? $0.modified > $1.modified
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return result
    }

    // MARK: Validation
    /// Confirms an item is still the one that was scanned, directly inside `folder`.
    func validate(_ item: CleanupItem, in folder: URL) throws {
        try validateFolder(folder, section: item.section)
        let url = item.url.standardizedFileURL
        guard Self.canonicalPath(url.deletingLastPathComponent()) == Self.canonicalPath(folder),
              url.resolvingSymlinksInPath() == url, !isProtected(url) else {
            throw CleanupError.changedOrProtected
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == item.inode,
              (attributes[.systemNumber] as? NSNumber)?.uint64Value == item.device else {
            throw CleanupError.changedOrProtected
        }
        // A folder's modification date changes whenever anything inside it is written,
        // so folders are identified by inode and device only. Files must also be
        // unmodified; items scanned without a date can't be compared.
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        if !isDirectory, item.modified != .distantPast,
           (attributes[.modificationDate] as? Date) != item.modified {
            throw CleanupError.changedOrProtected
        }
    }

    // MARK: Removal
    /// Trash items are deleted permanently; app bundles are moved to the Trash.
    func remove(_ items: [CleanupItem], in folder: URL, runningApps: Set<String>) -> CleanupResult {
        var result = CleanupResult()
        for item in items {
            do {
                try validate(item, in: folder)
                if let identifier = item.bundleIdentifier, runningApps.contains(identifier) {
                    throw CleanupError.runningApplication
                }
                switch item.section {
                case .trash: try FileManager.default.removeItem(at: item.url)
                case .applications: try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                case .recentFiles, .junk, .storage, .browsers: throw CleanupError.wrongFolder
                }
                result.removed.insert(item.id)
            } catch {
                if Self.isPermissionError(error) { result.needsAccess = true }
                result.failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// True when macOS privacy protection or file permissions blocked a write,
    /// including POSIX errors wrapped as the underlying error of a Cocoa error.
    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    // MARK: Helpers
    /// Path with symlinks resolved and no trailing slash, for reliable comparison.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func isProtected(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path == "/System" || path.hasPrefix("/System/")
            || path == Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }
}
