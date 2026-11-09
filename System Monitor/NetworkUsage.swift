import Foundation
import Darwin

// MARK: - Per-app network usage
/// Bytes per second one process sent and received over the last second.
nonisolated struct ProcessTraffic: Identifiable, Sendable, Equatable {
    let pid: pid_t
    let name: String
    let appPath: String?
    let download: Double
    let upload: Double
    var id: pid_t { pid }
    var total: Double { download + upload }
}

nonisolated enum NetworkUsageSampler {
    /// Runs `nettop` for two one-second samples in delta mode, so the second
    /// block holds each process's traffic over the last second. No admin rights needed.
    static func sample() async throws -> [ProcessTraffic] {
        let output = try await Shell.run(URL(fileURLWithPath: "/usr/bin/nettop"),
                                         ["-P", "-x", "-d", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"])
        guard output.succeeded else { throw Shell.Failure(output.message) }
        return parse(output.stdout)
    }

    /// Parses nettop CSV: a header line (",bytes_in,bytes_out,") starts each sample;
    /// rows look like "Google Chrome H.912,20325,16401,".
    static func parse(_ csv: String) -> [ProcessTraffic] {
        let blocks = csv.components(separatedBy: ",bytes_in,bytes_out,")
        guard let last = blocks.last, blocks.count > 1 else { return [] }
        var traffic: [ProcessTraffic] = []
        for line in last.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let down = Double(fields[1]), let up = Double(fields[2]),
                  down + up > 0 else { continue }
            let (name, appPath) = describe(pid: pid, fallback: String(fields[0][..<dot]))
            traffic.append(ProcessTraffic(pid: pid, name: name, appPath: appPath, download: down, upload: up))
        }
        return traffic.sorted { $0.total > $1.total }
    }

    /// nettop truncates names to 15 characters, so look up the full name and app bundle.
    private static func describe(pid: pid_t, fallback: String) -> (String, String?) {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return (fallback, nil) }
        let executable = String(cString: buffer)
        let appPath = executable.range(of: ".app/").map { String(executable[..<$0.lowerBound]) + ".app" }
        let name = appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? URL(fileURLWithPath: executable).lastPathComponent
        return (name, appPath)
    }
}
