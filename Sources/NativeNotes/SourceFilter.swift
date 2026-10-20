import Foundation

/// Attachment metadata filters; `unknown` covers locked or unavailable source data.
enum AttachmentFilter: String, CaseIterable, Identifiable {
    case all = "全部附件情况", none = "无附件", some = "含附件", many = "附件较多（≥5）", unknown = "附件情况未知"
    var id: String { rawValue }
}
/// Filters source notes by whether a local snapshot already exists.
enum ImportFilter: String, CaseIterable, Identifiable {
    case all = "全部导入状态", notImported = "未导入", imported = "已导入"
    var id: String { rawValue }
}
/// Filters readable and password-protected source notes.
enum AccessFilter: String, CaseIterable, Identifiable {
    case all = "全部访问状态", readable = "未受密码保护", locked = "受密码保护"
    var id: String { rawValue }
}
/// Composable source query evaluated entirely against catalog metadata.
struct SourceFilter {
    var query = ""
    var folder: String? = nil
    var attachments: AttachmentFilter = .all
    var imported: ImportFilter = .all
    var access: AccessFilter = .all
    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder != nil || attachments != .all || imported != .all || access != .all
    }
    func matches(_ note: SourceNote, importedIDs: Set<String>) -> Bool {
        guard !note.folderOnly else { return false }
        if let folder, folder != note.folder { return false }
        let haystack = note.title + " " + note.folder
        let words = query.split(whereSeparator: { $0.isWhitespace })
        guard words.allSatisfy({ haystack.localizedStandardContains(String($0)) }) else { return false }
        switch attachments {
        case .all: break
        case .none: guard note.attachmentCount == 0 else { return false }
        case .some: guard let count = note.attachmentCount, count > 0 else { return false }
        case .many: guard let count = note.attachmentCount, count >= 5 else { return false }
        case .unknown: guard note.attachmentCount == nil else { return false }
        }
        switch imported {
        case .all: break
        case .notImported: guard !importedIDs.contains(note.id) else { return false }
        case .imported: guard importedIDs.contains(note.id) else { return false }
        }
        switch access {
        case .all: break
        case .readable: guard !note.locked else { return false }
        case .locked: guard note.locked else { return false }
        }
        return true
    }
}
