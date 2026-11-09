import AppKit
import Darwin

// MARK: - Maintenance tasks
/// One-click maintenance scripts, similar to CleanMyMac's Performance module.
nonisolated enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case freeMemory, flushDNS, reindexSpotlight, thinSnapshots, rebuildLaunchServices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeMemory: "Purge disk cache"
        case .flushDNS: "Flush DNS cache"
        case .reindexSpotlight: "Reindex Spotlight"
        case .thinSnapshots: "Thin Time Machine snapshots"
        case .rebuildLaunchServices: "Rebuild Launch Services"
        }
    }

    var detail: String {
        switch self {
        case .freeMemory: "Empties the disk cache and inactive memory. macOS manages memory well on its own, so this only helps briefly, e.g. before a memory-heavy task. Watch Memory pressure instead."
        case .flushDNS: "Fixes websites that won’t load or resolve to an old address."
        case .reindexSpotlight: "Rebuilds the search index when Spotlight results are missing or wrong. Indexing takes a while."
        case .thinSnapshots: "Frees purgeable space held by local Time Machine snapshots."
        case .rebuildLaunchServices: "Fixes duplicate apps in “Open With” menus and wrong default apps."
        }
    }

    var symbol: String {
        switch self {
        case .freeMemory: "memorychip"
        case .flushDNS: "network.badge.shield.half.filled"
        case .reindexSpotlight: "magnifyingglass"
        case .thinSnapshots: "clock.arrow.circlepath"
        case .rebuildLaunchServices: "square.grid.3x3.square"
        }
    }

    /// Tasks that change system state need root and share one password prompt.
    var requiresAdmin: Bool { self != .rebuildLaunchServices }

    var command: String {
        switch self {
        case .freeMemory: "/usr/sbin/purge"
        case .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .reindexSpotlight: "/usr/bin/mdutil -E /"
        case .thinSnapshots: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"
        case .rebuildLaunchServices:
            // Runs as the user so it rebuilds *your* app database, not root's.
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user"
        }
    }
}

nonisolated enum MaintenanceRunner {
    /// Runs the chosen tasks and returns which succeeded. Admin tasks are batched
    /// into one script; each prints a marker so results can be told apart.
    static func run(_ tasks: [MaintenanceTask]) async throws -> [MaintenanceTask: Bool] {
        var results: [MaintenanceTask: Bool] = [:]
        let admin = tasks.filter(\.requiresAdmin)
        if !admin.isEmpty {
            let script = admin.map { "( \($0.command) ) >/dev/null 2>&1 && echo OK:\($0.rawValue) || echo FAIL:\($0.rawValue)" }
                .joined(separator: "; ")
            let output = try await Shell.runAsAdministrator(script, prompt: "System Monitor needs your password to run maintenance tasks.")
            for task in admin { results[task] = output.stdout.contains("OK:\(task.rawValue)") }
        }
        for task in tasks where !task.requiresAdmin {
            results[task] = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", task.command]).succeeded
        }
        return results
    }
}

// MARK: - Login & background items
/// A launch agent or daemon plist that starts software automatically.
nonisolated struct LaunchItem: Identifiable, Sendable {
    enum Scope: String, Sendable {
        case user = "Your account"
        case allUsers = "All users"
        case system = "System (background daemon)"
    }

    let url: URL
    let label: String
    let program: String?
    let scope: Scope
    var isDisabled: Bool
    /// Signature of the program the item launches; nil when unsigned or missing.
    var signer: CodeSigner? = nil
    var programExists = true
    var id: String { url.path }

    /// "Google Updater" from /Applications/Google Updater.app/…, or the label.
    var displayName: String {
        if let program, let range = program.range(of: ".app/") {
            return URL(fileURLWithPath: String(program[..<range.lowerBound])).lastPathComponent
        }
        return label
    }
}

actor LaunchItemService {
    private let uid = getuid()

    /// Reads plists from the three standard launchd folders, plus launchd's override
    /// lists to know which items have been disabled.
    func scan() async -> [LaunchItem] {
        let home = PermissionCenter.realHomeDirectory
        let folders: [(URL, LaunchItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsers),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system)
        ]
        let userDisabled = await disabledLabels(domain: "gui/\(uid)")
        let systemDisabled = await disabledLabels(domain: "system")
        var items: [LaunchItem] = []
        for (folder, scope) in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                guard let plist = NSDictionary(contentsOf: file) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                let overrides = scope == .system ? systemDisabled : userDisabled
                let disabled = overrides[label] ?? (plist["Disabled"] as? Bool ?? false)
                let exists = program.map { FileManager.default.fileExists(atPath: $0) } ?? false
                items.append(LaunchItem(url: file, label: label, program: program, scope: scope, isDisabled: disabled,
                                        signer: program.flatMap(CodeSigner.read(atPath:)), programExists: exists))
            }
        }
        return items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Parses `launchctl print-disabled`: lines like `"com.example.agent" => disabled`.
    private func disabledLabels(domain: String) async -> [String: Bool] {
        guard let output = try? await Shell.run(URL(fileURLWithPath: "/bin/launchctl"), ["print-disabled", domain]) else { return [:] }
        var result: [String: Bool] = [:]
        for line in output.stdout.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            result[label] = state == "disabled" || state == "true"
        }
        return result
    }

    /// Enables or disables an item now and for future logins. System daemons need admin rights.
    func setEnabled(_ enabled: Bool, item: LaunchItem) async throws {
        let domain = item.scope == .system ? "system" : "gui/\(uid)"
        let target = "\(domain)/\(item.label)"
        // `enable/disable` persists the choice; bootstrap/bootout applies it immediately.
        let commands = enabled
            ? ["/bin/launchctl enable \(Shell.quote(target))",
               "/bin/launchctl bootstrap \(domain) \(Shell.quote(item.url.path)) 2>/dev/null || true"]
            : ["/bin/launchctl disable \(Shell.quote(target))",
               "/bin/launchctl bootout \(Shell.quote(target)) 2>/dev/null || true"]
        let script = commands.joined(separator: "; ")
        let output = item.scope == .system
            ? try await Shell.runAsAdministrator(script, prompt: "System Monitor needs your password to change a background item.")
            : try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
        guard output.succeeded else { throw Shell.Failure(output.message) }
    }
}

// MARK: - Heavy consumers (per-process CPU & memory)
nonisolated struct ProcessUsage: Identifiable, Sendable {
    let pid: pid_t
    let name: String
    let appPath: String?             // enclosing .app bundle, for its icon
    let cpu: Double                  // percent of one core (can exceed 100)
    let memory: UInt64               // physical footprint in bytes
    var id: pid_t { pid }
}

/// Samples CPU time and memory for every process this user can inspect. CPU usage is
/// the change in CPU time between samples, like Activity Monitor's "% CPU".
actor ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]          // CPU time in nanoseconds
    private var previousTime: UInt64 = 0
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sample() -> [ProcessUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTime > 0 ? Double(now - previousTime) : 0
        var current: [pid_t: UInt64] = [:]
        var usage: [ProcessUsage] = []
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }                   // other users' processes
            // rusage CPU times are in mach time units on Apple silicon.
            let cpuTime = UInt64(Double(info.ri_user_time + info.ri_system_time) * timebase)
            current[pid] = cpuTime
            let cpu = elapsed > 0 ? previous[pid].map { Double(cpuTime &- $0) / elapsed * 100 } ?? 0 : 0

            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            let appPath = executable.range(of: ".app/").map { String(executable[..<$0.lowerBound]) + ".app" }
            let name = appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? URL(fileURLWithPath: executable).lastPathComponent
            usage.append(ProcessUsage(pid: pid, name: name, appPath: appPath, cpu: max(cpu, 0),
                                      memory: info.ri_phys_footprint))
        }
        previous = current
        previousTime = now
        return usage
    }
}

// MARK: - Hung app detection
/// Detects "Not Responding" apps when private window-server symbols are enabled;
/// omitted in Mac App Store builds to comply with App Store Guideline 2.5.1 (Public APIs).
@MainActor
enum HungAppDetector {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias PSNFunction = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias UnresponsiveFunction = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool

    private static let functions: (ConnectionFunction, PSNFunction, UnresponsiveFunction)? = {
        #if ENABLE_PRIVATE_APIS
        let handle = dlopen(nil, RTLD_NOW)
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let psn = dlsym(handle, "GetProcessForPID"),
              let unresponsive = dlsym(handle, "CGSEventIsAppUnresponsive") else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFunction.self),
                unsafeBitCast(psn, to: PSNFunction.self),
                unsafeBitCast(unresponsive, to: UnresponsiveFunction.self))
        #else
        return nil
        #endif
    }()

    static var isAvailable: Bool { functions != nil }

    /// Regular (Dock) apps that the window server reports as not responding.
    static func unresponsiveApps() -> [NSRunningApplication] {
        guard let (connection, processFor, isUnresponsive) = functions else { return [] }
        let connectionID = connection()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, !app.isTerminated else { return false }
            var psn = ProcessSerialNumber()
            guard processFor(app.processIdentifier, &psn) == noErr else { return false }
            return isUnresponsive(connectionID, &psn)
        }
    }
}
