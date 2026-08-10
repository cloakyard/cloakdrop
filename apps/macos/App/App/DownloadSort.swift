/// How the content list is ordered.
enum DownloadSort: String, CaseIterable, Identifiable {
    case dateAdded, name, size, status
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .name: return "Name"
        case .size: return "Size"
        case .status: return "Status"
        }
    }
}
