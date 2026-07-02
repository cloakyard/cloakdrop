import Foundation
import Security
import DownloadModels

/// Assesses a finished file's code signature. A protocol seam so the engine's finalize path can be
/// exercised with an injected stub in tests, and driven by the real Security framework in production.
public protocol CodeSignatureInspecting: Sendable {
    /// Assess the code signature of the file at `fileURL`. Returns `nil` when the file isn't a
    /// recognizable code object — so the caller records *no* signature rather than a false "unsigned".
    func assess(fileURL: URL) -> SignatureAssessment?
}

/// Production inspector backed by the Security framework (`SecStaticCode`). Entirely in-process and
/// offline: it reads the signature already embedded in the file and validates its seal — no
/// Gatekeeper round-trip and no network egress, in keeping with CloakDrop's privacy constraint.
/// Stateless, hence trivially `Sendable`.
public struct SecCodeSignatureInspector: CodeSignatureInspecting {
    public init() {}

    public func assess(fileURL: URL) -> SignatureAssessment? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(fileURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil   // not a recognizable code object → make no claim about it
        }

        let validity = SecStaticCodeCheckValidity(staticCode, [], nil)
        if validity == errSecSuccess {
            let identity = Self.signingIdentity(of: staticCode)
            return SignatureAssessment(status: .valid, authority: identity.authority)
        }
        if validity == errSecCSUnsigned {
            return SignatureAssessment(status: .unsigned)
        }
        // Some other failure. Only call it "invalid" when a signature is actually present (tampered,
        // expired, broken chain); a status like "bad object format" means it isn't a code object we
        // can judge, so make no claim (nil) rather than a misleading "invalid".
        let identity = Self.signingIdentity(of: staticCode)
        guard identity.authority != nil || identity.team != nil else { return nil }
        return SignatureAssessment(status: .invalid, authority: identity.authority)
    }

    /// The leaf certificate's common name and the team identifier from the signature, best-effort.
    private static func signingIdentity(of code: SecStaticCode) -> (authority: String?, team: String?) {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return (nil, nil)
        }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        var authority: String?
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            var commonName: CFString?
            if SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess {
                authority = commonName as String?
            }
        }
        return (authority, team)
    }
}
