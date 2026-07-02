import Foundation

/// Parses a Metalink document into `MetalinkFile`s. Handles both Metalink 4 (RFC 5854, `.meta4`) and
/// the older 3.0 layout (`<files><file><resources>/<verification>`), which differ in structure and
/// in how they rank mirrors (4's `priority`, lower-is-better, vs 3's `preference`, higher-is-better).
///
/// Pure and I/O-free — built on Foundation's `XMLParser`, no third-party dependency. Only http(s)
/// mirrors are kept; ftp/magnet/rsync sources are dropped since the engine speaks HTTP.
public enum MetalinkParser {
    public static func parse(_ data: Data) throws -> [MetalinkFile] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true          // report local element names, namespace-agnostic
        let delegate = MetalinkParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw DownloadError.underlying(reason: "The Metalink document could not be parsed.")
        }
        return delegate.files
    }
}

/// SAX delegate: one file is assembled at a time (Metalink files never nest), reset on `<file>` and
/// committed on its close.
private final class MetalinkParserDelegate: NSObject, XMLParserDelegate {
    private(set) var files: [MetalinkFile] = []

    // In-progress file state.
    private var name = ""
    private var size: Int64?
    private var wholeHashes: [ChecksumAlgorithm: String] = [:]
    private var sources: [MetalinkSource] = []
    private var pieceLength: Int64?
    private var pieceAlgorithm: ChecksumAlgorithm?
    private var pieceHashes: [String] = []

    // Per-element scratch.
    private var text = ""
    private var inPieces = false
    private var currentHashAlgorithm: ChecksumAlgorithm?
    private var currentURLPriority: Int?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        text = ""
        switch elementName.lowercased() {
        case "file":
            resetFile()
            name = attributes["name"] ?? ""
        case "pieces":
            inPieces = true
            pieceLength = attributes["length"].flatMap { Int64($0) }
            pieceAlgorithm = Self.algorithm(from: attributes["type"])
        case "hash":
            currentHashAlgorithm = Self.algorithm(from: attributes["type"])
        case "url":
            currentURLPriority = Self.priority(from: attributes)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "size":
            size = Int64(value)
        case "hash":
            if inPieces {
                if !value.isEmpty { pieceHashes.append(value.lowercased()) }
            } else if let algorithm = currentHashAlgorithm {
                wholeHashes[algorithm] = value.lowercased()
            }
            currentHashAlgorithm = nil
        case "pieces":
            inPieces = false
        case "url":
            if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                sources.append(MetalinkSource(url: url, priority: currentURLPriority ?? Self.defaultPriority))
            }
            currentURLPriority = nil
        case "file":
            commitFile()
        default:
            break
        }
        text = ""
    }

    // MARK: - Assembly

    private func resetFile() {
        name = ""; size = nil; wholeHashes = [:]; sources = []
        pieceLength = nil; pieceAlgorithm = nil; pieceHashes = []
        inPieces = false; currentHashAlgorithm = nil; currentURLPriority = nil
    }

    private func commitFile() {
        guard !sources.isEmpty else { return }        // a file with no usable mirror isn't downloadable
        files.append(MetalinkFile(
            name: name,
            size: size,
            sources: sources.sorted { $0.priority < $1.priority },
            checksum: Self.strongest(of: wholeHashes),
            pieceLength: pieceLength,
            pieceAlgorithm: pieceAlgorithm,
            pieceHashes: pieceHashes
        ))
    }

    // MARK: - Helpers

    static let defaultPriority = 1_000_000

    /// Normalise a hash `type` (`sha-256`, `sha256`, `SHA-1`, `md5`, …) to a known algorithm.
    static func algorithm(from type: String?) -> ChecksumAlgorithm? {
        guard let type else { return nil }
        switch type.lowercased().replacingOccurrences(of: "-", with: "") {
        case "sha256": return .sha256
        case "sha1": return .sha1
        case "md5": return .md5
        default: return nil
        }
    }

    /// Metalink 4 `priority` (lower is better) if present; otherwise a Metalink 3 `preference` (higher
    /// is better) mapped into the same lower-is-better space; otherwise the default.
    static func priority(from attributes: [String: String]) -> Int {
        if let priority = attributes["priority"].flatMap({ Int($0) }) { return priority }
        if let preference = attributes["preference"].flatMap({ Int($0) }) { return defaultPriority - preference }
        return defaultPriority
    }

    /// Pick the strongest usable whole-file digest (SHA-256 › SHA-1 › MD5).
    static func strongest(of hashes: [ChecksumAlgorithm: String]) -> ChecksumExpectation? {
        for algorithm in [ChecksumAlgorithm.sha256, .sha1, .md5] {
            if let hex = hashes[algorithm] {
                let expectation = ChecksumExpectation(algorithm: algorithm, expectedHex: hex)
                if expectation.isUsable { return expectation }
            }
        }
        return nil
    }
}
