import Foundation
import Security

// MARK: - Code signing
/// Who signed an app or tool, read from its code signature.
nonisolated struct CodeSigner: Equatable, Sendable {
    /// Developer team identifier, e.g. "EQHXZ8M8AV". Nil for Apple's own code.
    let teamID: String?
    /// "Google LLC", "Apple", or the certificate's summary.
    let name: String
    let isApple: Bool

    /// Reads and validates the signature at `path`. Returns nil when the code is
    /// unsigned, its signature is broken, or the file doesn't exist.
    static func read(atPath path: String) -> CodeSigner? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let isApple = info[kSecCodeInfoPlatformIdentifier as String] != nil
            || (teamID == nil && (info[kSecCodeInfoIdentifier as String] as? String)?.hasPrefix("com.apple.") == true)
        if isApple { return CodeSigner(teamID: nil, name: "Apple", isApple: true) }

        // "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC".
        var name = teamID.map { "Team \($0)" } ?? "Ad-hoc signature"
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            name = summary
            if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
            if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
            name = name.trimmingCharacters(in: .whitespaces)
        }
        return CodeSigner(teamID: teamID, name: name, isApple: false)
    }
}
