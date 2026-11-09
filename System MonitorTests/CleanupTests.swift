import Foundation
import Testing
@testable import System_Monitor

// MARK: - Trash & app cleanup
struct CleanupTests {
    /// A temporary home folder with an empty .Trash inside it.
    private func makeHome() throws -> (home: URL, trash: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trash = home.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return (home, trash)
    }

    @Test func trashScanIncludesHiddenFilesButSkipsSymlinksAndDSStore() async throws {
        let (home, trash) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("keep".utf8).write(to: trash.appendingPathComponent("document.txt"))
        try Data().write(to: trash.appendingPathComponent(".hidden"))
        try Data().write(to: trash.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: trash.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("link"),
                                                   withDestinationURL: trash.appendingPathComponent("document.txt"))
        let scan = try await CleanupService(homeURL: home).scan(folder: trash, section: .trash)
        #expect(Set(scan.items.map(\.name)) == [".hidden", "document.txt", "folder"])
    }

    @Test func rejectsChangedFilesAndWrongFolders() async throws {
        let (home, trash) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = trash.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: file)
        let service = CleanupService(homeURL: home)
        let item = try #require(try await service.scan(folder: trash, section: .trash).items.first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        await #expect(throws: (any Error).self) { try await service.validate(item, in: trash) }
        await #expect(throws: (any Error).self) { try await service.validateFolder(home, section: .trash) }
        await #expect(throws: (any Error).self) { try await service.validateFolder(trash, section: .browsers) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func folderStaysValidWhenItsContentsChange() async throws {
        let (home, trash) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: trash.appendingPathComponent("Project"), withIntermediateDirectories: true)
        let service = CleanupService(homeURL: home)
        let item = try #require(try await service.scan(folder: trash, section: .trash).items.first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: item.url.path)
        try await service.validate(item, in: trash)
    }

    @Test func removesSelectedTrashItemsPermanently() async throws {
        let (home, trash) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: trash.appendingPathComponent("a.txt"))
        try Data().write(to: trash.appendingPathComponent("b.txt"))
        let service = CleanupService(homeURL: home)
        let items = try await service.scan(folder: trash, section: .trash).items
        let result = await service.remove(items.filter { $0.name == "a.txt" }, in: trash, runningApps: [])
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: trash.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("b.txt").path))
    }

    @Test func detectsWrappedPermissionErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: posix])
        #expect(CleanupService.isPermissionError(wrapped))
        #expect(CleanupService.isPermissionError(CocoaError(.fileWriteNoPermission)))
        #expect(!CleanupService.isPermissionError(CocoaError(.fileNoSuchFile)))
    }
}
