import Foundation

// MARK: - Shell
/// Runs command-line tools (brew, mas, speedtest, launchctl, purge…) off the main
/// actor, streaming their output and terminating them if the calling task is cancelled.
nonisolated enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }

        /// Most useful error text: the last few lines of stderr, falling back to stdout.
        var message: String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
            return text.split(separator: "\n").suffix(3).joined(separator: "\n")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// GUI apps don't inherit the user's shell PATH, so Homebrew tools need explicit lookup.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Finds a Homebrew-installed tool on Apple silicon (/opt/homebrew) or Intel (/usr/local).
    static func tool(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var brew: URL? { tool("brew") }

    // MARK: Running a process
    /// Runs `executable` and returns its exit status and output. `onLine` receives each
    /// output line as it arrives (used for live progress from brew and speedtest).
    static func run(_ executable: URL, _ arguments: [String], environment extra: [String: String] = [:],
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment.merge(extra) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice      // never wait on a terminal prompt

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = OutputCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, error: false) }
        err.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, error: true) }

        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    // Stop streaming, then drain whatever is still buffered in the pipes.
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.append(out.fileHandleForReading.readDataToEndOfFile(), error: false)
                    collector.append(err.fileHandleForReading.readDataToEndOfFile(), error: true)
                    continuation.resume(returning: collector.finish(status: process.terminationStatus))
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return output
    }

    // MARK: Administrator commands
    /// Runs a shell script as root after macOS shows its standard password dialog.
    /// One call = one password prompt, so related commands should be batched.
    static func runAsAdministrator(_ script: String, prompt: String) async throws -> Output {
        let source = "do shell script \(appleScriptLiteral(script)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
        let output = try await run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source])
        if output.stderr.contains("(-128)") { throw Failure("Cancelled at the password prompt.") }
        return output
    }

    /// Quotes text for use inside an AppleScript string literal.
    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Quotes text as a single POSIX shell word.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Helper for `sudo -A` (via SUDO_ASKPASS): installers that need root show a
    /// password dialog instead of hanging on a terminal prompt nobody can see.
    static func askpassScript() throws -> URL {
        let script = AppSupport.folder.appendingPathComponent("askpass.sh")
        let body = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'text returned of (display dialog "An app update needs your administrator password." default answer "" with hidden answer with title "System Monitor" with icon caution)'

        """
        try Data(body.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

// MARK: - Output collection
/// Thread-safe buffer for pipe output; pipes deliver data on background queues.
private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var pending = Data()                       // partial line awaiting a newline
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        if error { stderr.append(data) } else { stdout.append(data) }
        if onLine != nil {
            // Split complete lines out of the stream; keep the remainder for next time.
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lock.unlock()
        for line in lines where !line.isEmpty { onLine?(line) }
    }

    func finish(status: Int32) -> Shell.Output {
        lock.lock(); defer { lock.unlock() }
        return Shell.Output(status: status, stdout: String(decoding: stdout, as: UTF8.self),
                            stderr: String(decoding: stderr, as: UTF8.self))
    }
}
