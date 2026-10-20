import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Persistent document model

/// A stable, codable table cell. Identity is preserved while rows and columns move.
struct EditorCell: Codable, Identifiable, Equatable { var id = UUID().uuidString; var text = "" }
/// A stable column identity shared by every row in an `EditorTable`.
struct EditorColumn: Codable, Identifiable, Equatable { var id = UUID().uuidString }
/// A table row whose cells always match the table's column count.
struct EditorRow: Codable, Identifiable, Equatable { var id = UUID().uuidString; var cells: [EditorCell] }
/// Rectangular table data stored inside a document block.
struct EditorTable: Codable, Equatable {
    var columns: [EditorColumn]
    var rows: [EditorRow]
    init(rows: Int, columns: Int) {
        self.columns = (0..<max(1, columns)).map { _ in EditorColumn() }
        self.rows = (0..<max(1, rows)).map { _ in EditorRow(cells: (0..<max(1, columns)).map { _ in EditorCell() }) }
    }
}
/// The semantic kinds supported by the block editor.
enum BlockKind: String, Codable, CaseIterable, Identifiable {
    case paragraph, heading, todo, bullet, numbered, lowerAlpha, upperAlpha, lowerRoman, upperRoman, table
    var id: String { rawValue }
    var title: String {
        switch self {
        case .paragraph: return "正文"; case .heading: return "标题"; case .todo: return "待办"; case .bullet: return "• 项目符号"
        case .numbered: return "1. 2. 3."; case .lowerAlpha: return "a. b. c."; case .upperAlpha: return "A. B. C."
        case .lowerRoman: return "i. ii. iii."; case .upperRoman: return "I. II. III."; case .table: return "表格"
        }
    }
    var ordered: Bool { [.numbered, .lowerAlpha, .upperAlpha, .lowerRoman, .upperRoman].contains(self) }
    var isList: Bool { ordered || self == .bullet || self == .todo }
}
/// A three-state value because imported Notes HTML may omit checkbox state.
enum TodoState: String, Codable { case unknown, open, done }
/// The smallest independently editable and reorderable unit in a local document.
struct EditorBlock: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: BlockKind = .paragraph
    var text = ""
    var richText: Data? = nil
    var indent = 0
    var ordinal = 1
    var todo: TodoState = .open
    var table: EditorTable? = nil
    var marker: String {
        switch kind {
        case .bullet: return "•"
        case .numbered: return "\(ordinal)."
        case .lowerAlpha: return ListRules.alpha(ordinal).lowercased() + "."
        case .upperAlpha: return ListRules.alpha(ordinal) + "."
        case .lowerRoman: return ListRules.roman(ordinal).lowercased() + "."
        case .upperRoman: return ListRules.roman(ordinal) + "."
        default: return ""
        }
    }
}
/// Versioned on-disk representation of one local note.
struct EditorDocument: Codable, Equatable {
    var version = 1
    var taskPresentation: Int? = nil
    var id = UUID().uuidString
    var revision = UUID().uuidString
    var sourceHash: String
    var title: String
    var blocks: [EditorBlock]
}
/// A one-shot focus request. The token lets repeated requests target the same block.
struct EditorFocus: Equatable { var id: String; var cursor: Int; var token = UUID() }
/// Cross-view drag payload scoped to a single document identifier.
struct EditorDrag: Codable {
    static let type = "local.nativenotes.editor-item"
    var document: String
    var kind: String
    var block: String
    var row: String? = nil
    var column: String? = nil
}
enum EditorDrop { case block(String), row(String, String), column(String, String), cell(String, String, String) }

// MARK: - List parsing and source import

/// Parses list shortcuts and produces display markers without storing derived text.
enum ListRules {
    static func alpha(_ value: Int) -> String {
        var n = max(1, value), result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
    static func roman(_ value: Int) -> String {
        guard value > 0 && value < 4000 else { return String(value) }
        var n = value, result = ""
        for (amount, symbol) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
            while n >= amount { result += symbol; n -= amount }
        }
        return result
    }
    static func romanValue(_ s: String) -> Int? {
        let values: [Character: Int] = ["I":1,"V":5,"X":10,"L":50,"C":100,"D":500,"M":1000]
        var total = 0, previous = 0
        for char in s.uppercased().reversed() {
            guard let n = values[char] else { return nil }
            total += n < previous ? -n : n; previous = max(previous, n)
        }
        return total > 0 && total < 4000 && roman(total) == s.uppercased() ? total : nil
    }
    static func parse(_ text: String) -> (BlockKind, Int, TodoState, String)? {
        for prefix in ["- [ ] ", "[ ] ", "[] ", "☐ "] where text.hasPrefix(prefix) { return (.todo, 1, .open, String(text.dropFirst(prefix.count))) }
        for prefix in ["- [x] ", "- [X] ", "[x] ", "[X] ", "☑ "] where text.hasPrefix(prefix) { return (.todo, 1, .done, String(text.dropFirst(prefix.count))) }
        for prefix in ["- ", "* ", "+ ", "• "] where text.hasPrefix(prefix) { return (.bullet, 1, .open, String(text.dropFirst(prefix.count))) }
        guard let regex = try? NSRegularExpression(pattern: "^([0-9]{1,6}|[a-zA-Z]{1,10})[.)]\\s(.*)$", options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let tokenRange = Range(match.range(at: 1), in: text), let contentRange = Range(match.range(at: 2), in: text) else { return nil }
        let token = String(text[tokenRange]), rest = String(text[contentRange])
        if let n = Int(token), n > 0 { return (.numbered, n, .open, rest) }
        if token.lowercased() == "i" || token.count > 1, let n = romanValue(token) { return (token == token.uppercased() ? .upperRoman : .lowerRoman, n, .open, rest) }
        if token.count == 1, let scalar = token.uppercased().unicodeScalars.first { return (token == token.uppercased() ? .upperAlpha : .lowerAlpha, Int(scalar.value) - 64, .open, rest) }
        return nil
    }
}

/// Converts the limited HTML/plain-text snapshot returned by Notes into editable blocks.
/// Missing source semantics are kept unknown instead of being guessed.
enum DocumentImporter {
    static func hash(_ html: String, _ text: String) -> String { SHA256.hash(data: Data((html + "\u{0}" + text).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func make(title: String, html: String, text: String) -> EditorDocument {
        var blocks: [EditorBlock] = []
        func inline(_ node: XMLNode) -> String {
            if node.kind == .text { return node.stringValue ?? "" }
            let tag = node.name?.lowercased() ?? ""
            if tag == "br" { return "\n" }
            if ["ul", "ol", "table", "script", "style", "input"].contains(tag) { return "" }
            let value = (node.children ?? []).map(inline).joined()
            if tag == "a", let href = (node as? XMLElement)?.attribute(forName: "href")?.stringValue,
               href.hasPrefix("http"), value != href { return value + " (" + href + ")" }
            return value
        }
        func walk(_ node: XMLNode, indent: Int = 0) {
            let tag = node.name?.lowercased() ?? ""
            if ["script", "style", "head"].contains(tag) { return }
            if tag == "table", let element = node as? XMLElement {
                let rowNodes = ((try? element.nodes(forXPath: ".//tr")) ?? []).compactMap { $0 as? XMLElement }
                let values = rowNodes.map { row in (row.children ?? []).filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }.map { inline($0).trimmingCharacters(in: .whitespacesAndNewlines) } }
                if let count = values.map(\.count).max(), count > 0 {
                    var table = EditorTable(rows: values.count, columns: count)
                    for r in values.indices { for c in values[r].indices { table.rows[r].cells[c].text = values[r][c] } }
                    blocks.append(EditorBlock(kind: .table, table: table))
                }
                return
            }
            if tag == "ul" || tag == "ol" {
                let list = node as? XMLElement
                let type = list?.attribute(forName: "type")?.stringValue
                let style: BlockKind = tag == "ul" ? .bullet : ["a":.lowerAlpha,"A":.upperAlpha,"i":.lowerRoman,"I":.upperRoman][type ?? ""] ?? .numbered
                var number = Int(list?.attribute(forName: "start")?.stringValue ?? "1") ?? 1
                for item in node.children ?? [] where item.name?.lowercased() == "li" {
                    let checkbox = ((try? item.nodes(forXPath: ".//input[@type='checkbox']")) ?? []).first as? XMLElement
                    blocks.append(EditorBlock(kind: checkbox == nil ? style : .todo, text: inline(item).trimmingCharacters(in: .whitespacesAndNewlines), indent: indent, ordinal: number, todo: checkbox?.attribute(forName: "checked") == nil ? .open : .done))
                    number += 1
                    for child in item.children ?? [] where ["ul", "ol"].contains(child.name?.lowercased() ?? "") { walk(child, indent: min(6, indent + 1)) }
                }
                return
            }
            if ["object", "embed", "iframe", "img"].contains(tag) {
                blocks.append(EditorBlock(text: "[未完整导入的嵌入内容，请在 Apple Notes 原文核对]")); return
            }
            if ["h1","h2","h3","h4","p"].contains(tag) {
                blocks.append(EditorBlock(kind: tag == "p" ? .paragraph : .heading, text: inline(node).trimmingCharacters(in: .whitespacesAndNewlines))); return
            }
            if tag == "br" { blocks.append(EditorBlock()); return }
            if node.kind == .text {
                let value = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { blocks.append(EditorBlock(text: value)) }
                return
            }
            let hasBlocks = (node.children ?? []).contains { ["div","p","h1","h2","h3","h4","ul","ol","table","object","img"].contains($0.name?.lowercased() ?? "") }
            if tag == "div" && !hasBlocks {
                blocks.append(EditorBlock(text: inline(node).trimmingCharacters(in: .whitespacesAndNewlines)))
            } else { for child in node.children ?? [] { walk(child, indent: indent) } }
        }
        if !html.isEmpty, let xml = try? XMLDocument(xmlString: "<html><body>" + html + "</body></html>", options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) {
            if let body = try? xml.nodes(forXPath: "//body").first { walk(body) }
        }
        if blocks.isEmpty { blocks = text.components(separatedBy: "\n").map { EditorBlock(text: $0) } }
        if blocks.isEmpty { blocks = [EditorBlock()] }
        return EditorDocument(sourceHash: hash(html, text), title: title, blocks: blocks)
    }
}

// MARK: - Editing session and persistence

/// Main-actor document controller responsible for edits, undo, validation and atomic saves.
@MainActor final class LocalEditor: ObservableObject {
    @Published private(set) var document: EditorDocument
    @Published var focus: EditorFocus?
    @Published var dragStatus = ""
    @Published private(set) var saveError: String?
    @Published private(set) var loadError: String?
    @Published private(set) var dirty = false
    let file: URL
    private var expectedRevision: String?
    var hasSaved: Bool { expectedRevision != nil }
    @Published private(set) var undoStack: [EditorDocument] = []
    @Published private(set) var redoStack: [EditorDocument] = []
    /// Keeps demo documents separate so UI testing cannot touch normal local edits.
    static func directory(demo: Bool) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeNotes/" + (demo ? "DemoEdits" : "LocalEdits"), isDirectory: true)
    }
    /// Reuses an unsaved in-memory model for the same file rather than discarding edits.
    static func open(sourceID: String, title: String, html: String, text: String, directory: URL) -> LocalEditor {
        let key = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".json")
        if let retained = EditorRegistry.unsaved.first(where: { $0.file == file }) { return retained }
        return LocalEditor(sourceID: sourceID, title: title, html: html, text: text, directory: directory)
    }
    init(sourceID: String, title: String, html: String, text: String, directory: URL) {
        let key = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(key + ".json")
        document = DocumentImporter.make(title: title, html: html, text: text)
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let saved = try JSONDecoder().decode(EditorDocument.self, from: Data(contentsOf: file))
                guard Self.valid(saved) else { throw NSError(domain: "LocalEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地副本结构或版本不受支持；未覆盖文件。文件：\(file.path)"]) }
                document = saved; expectedRevision = saved.revision
            } catch { loadError = error.localizedDescription }
        }
        if title == "任务列表", document.taskPresentation == nil, loadError == nil {
            mutate { doc in
                doc.taskPresentation = 1
                for i in doc.blocks.indices where doc.blocks[i].kind == .bullet || doc.blocks[i].kind.ordered {
                    doc.blocks[i].kind = .todo; doc.blocks[i].todo = .open
                }
                // Remove imported spacer rows and the repeated source title, preserving task IDs and states.
                doc.blocks.removeAll { $0.kind == .paragraph && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let first = doc.blocks.first, first.kind == .heading, first.text == title { doc.blocks.removeFirst() }
                if doc.blocks.isEmpty { doc.blocks = [EditorBlock()] }
            }
        }
        EditorRegistry.models.removeAll { $0.value == nil }
        EditorRegistry.models.append(WeakEditor(self))
    }
    /// Rejects unsupported or malformed documents before they can replace user data.
    static func valid(_ doc: EditorDocument) -> Bool {
        guard doc.version == 1, !doc.blocks.isEmpty, Set(doc.blocks.map(\.id)).count == doc.blocks.count else { return false }
        return doc.blocks.allSatisfy { b in
            guard b.indent >= 0 && b.indent <= 6 && b.ordinal > 0 else { return false }
            if b.kind == .table {
                guard let table = b.table, !table.columns.isEmpty, !table.rows.isEmpty else { return false }
                return table.rows.allSatisfy { $0.cells.count == table.columns.count }
            }
            return true
        }
    }
    func mutate(_ change: (inout EditorDocument) -> Void) {
        guard loadError == nil else { return }
        var next = document; change(&next)
        for i in next.blocks.indices where next.blocks[i].kind.ordered && i > 0 {
            let previous = next.blocks[i - 1]
            if previous.kind == next.blocks[i].kind && previous.indent == next.blocks[i].indent { next.blocks[i].ordinal = previous.ordinal + 1 }
        }
        guard Self.valid(next), next != document else { return }
        undoStack.append(document)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        next.revision = UUID().uuidString; document = next; dirty = true; saveNow()
    }
    func undo() {
        guard loadError == nil, var previous = undoStack.popLast() else { return }
        redoStack.append(document); previous.revision = UUID().uuidString
        document = previous; dirty = true; saveNow()
    }
    func redo() {
        guard loadError == nil, var next = redoStack.popLast() else { return }
        undoStack.append(document); next.revision = UUID().uuidString
        document = next; dirty = true; saveNow()
    }
    func reorderBlocks(_ ids: [String]) {
        guard ids.count == document.blocks.count, Set(ids) == Set(document.blocks.map(\.id)) else { return }
        mutate { doc in
            let lookup = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0) })
            doc.blocks = ids.compactMap { lookup[$0] }
        }
    }
    func moveBlocks(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ document.blocks.indices.contains($0) }), (0...document.blocks.count).contains(destination) else { return }
        mutate { doc in
            let moving = offsets.map { doc.blocks[$0] }
            let insertion = destination - offsets.filter { $0 < destination }.count
            for index in offsets.reversed() { doc.blocks.remove(at: index) }
            doc.blocks.insert(contentsOf: moving, at: insertion)
        }
    }
    func convertListsToTodos(all: Bool = false) {
        mutate { d in
            for i in d.blocks.indices where d.blocks[i].kind == .bullet || (all && d.blocks[i].kind.ordered) {
                d.blocks[i].kind = .todo; d.blocks[i].todo = .unknown
            }
        }
    }
    func saveNow() {
        guard dirty && loadError == nil else { return }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let disk = try JSONDecoder().decode(EditorDocument.self, from: Data(contentsOf: file))
                guard disk.revision == expectedRevision else { throw NSError(domain: "LocalEditor", code: 2, userInfo: [NSLocalizedDescriptionKey: "另一窗口已修改此副本，未覆盖磁盘内容。请先复制当前未保存的文字，再重新打开此笔记。未保存的修改仍保留在当前窗口。文件：\(file.path)"]) }
            } else if expectedRevision != nil { throw NSError(domain: "LocalEditor", code: 3, userInfo: [NSLocalizedDescriptionKey: "本地副本文件被外部移除，未自动重建，请先复制当前内容。"] ) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
            expectedRevision = document.revision; dirty = false; saveError = nil
            EditorRegistry.unsaved.removeAll { $0 === self }
        } catch {
            saveError = error.localizedDescription
            if !EditorRegistry.unsaved.contains(where: { $0 === self }) { EditorRegistry.unsaved.append(self) }
        }
    }
    func saveRecoveryCopy() {
        let panel = NSSavePanel()
        panel.title = "另存未保存的本地副本"
        panel.nameFieldStringValue = (document.title.isEmpty ? "NativeNotes 副本" : document.title.replacingOccurrences(of: "/", with: "-")) + ".json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != file.standardizedFileURL else { saveError = "请另存到其他文件，原文件存在版本冲突，不会覆盖。"; return }
        do {
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
            dirty = false; saveError = nil
            loadError = "完整本地副本已另存至 \(url.path)。原文件未覆盖；切换笔记再回来可重新读取磁盘版本。"
            EditorRegistry.unsaved.removeAll { $0 === self }
        } catch { saveError = error.localizedDescription }
    }
    func blockID(for focusID: String) -> String? {
        document.blocks.first { $0.id == focusID || ($0.table?.rows.contains { row in row.cells.contains { $0.id == focusID } } ?? false) }?.id
    }
    func focus(_ id: String, cursor: Int = 0) { focus = EditorFocus(id: id, cursor: cursor) }
    func setTitle(_ text: String) { mutate { $0.title = text } }
    func setText(_ id: String, _ value: String) { setRichText(id, text: value, richText: nil) }
    func setRichText(_ id: String, text value: String, richText: Data?) {
        mutate { doc in
            guard let i = doc.blocks.firstIndex(where: { $0.id == id }) else { return }
            doc.blocks[i].text = value
            doc.blocks[i].richText = richText
            if doc.blocks[i].kind == .paragraph, let (kind, ordinal, todo, text) = ListRules.parse(value) {
                doc.blocks[i].kind = kind; doc.blocks[i].ordinal = ordinal; doc.blocks[i].todo = todo; doc.blocks[i].text = text; doc.blocks[i].richText = nil
            }
        }
    }
    func setKind(_ id: String, _ kind: BlockKind) {
        mutate { doc in
            guard let i = doc.blocks.firstIndex(where: { $0.id == id }), kind != .table else { return }
            if kind == .todo && doc.blocks[i].kind != .todo { doc.blocks[i].todo = .unknown }
            if doc.blocks[i].kind == .heading || kind == .heading { doc.blocks[i].richText = nil }
            doc.blocks[i].kind = kind
        }
    }
    func toggleTodo(_ id: String) {
        mutate { doc in if let i = doc.blocks.firstIndex(where: { $0.id == id }) { doc.blocks[i].todo = doc.blocks[i].todo == .done ? .open : .done } }
    }
    @discardableResult func enter(_ id: String, range: NSRange) -> Bool {
        guard let block = document.blocks.first(where: { $0.id == id }) else { return false }
        if block.kind.isList && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutate { d in if let i = d.blocks.firstIndex(where: { $0.id == id }) { d.blocks[i].kind = .paragraph; d.blocks[i].indent = 0 } }
            focus(id); return true
        }
        let source = block.text as NSString
        let start = min(range.location, source.length), end = min(start + range.length, source.length)
        let prefix = source.substring(to: start), suffix = source.substring(from: end)
        var next = EditorBlock(kind: block.kind == .heading ? .paragraph : block.kind, text: suffix, indent: block.indent, ordinal: block.ordinal + 1)
        if next.kind == .todo { next.todo = .open }
        if block.kind != .heading { next.richText = RichTextCodec.slice(block.richText, text: block.text, range: NSRange(location: end, length: source.length - end)) }
        let prefixRTF = RichTextCodec.slice(block.richText, text: block.text, range: NSRange(location: 0, length: start))
        mutate { d in
            guard let i = d.blocks.firstIndex(where: { $0.id == id }) else { return }
            d.blocks[i].text = prefix; d.blocks[i].richText = prefixRTF; d.blocks.insert(next, at: i + 1)
        }
        focus(next.id); return true
    }
    @discardableResult func backspace(_ id: String) -> Bool {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return false }
        if document.blocks[index].kind != .paragraph {
            setKind(id, .paragraph); return true
        }
        guard index > 0, document.blocks[index - 1].kind != .table else { return false }
        let previous = document.blocks[index - 1], cursor = (previous.text as NSString).length
        let mergedRTF = RichTextCodec.joined(previous, document.blocks[index])
        mutate { d in d.blocks[index - 1].text += d.blocks[index].text; d.blocks[index - 1].richText = mergedRTF; d.blocks.remove(at: index) }
        focus(previous.id, cursor: cursor); return true
    }
    func indent(_ id: String, by value: Int) {
        mutate { d in if let i = d.blocks.firstIndex(where: { $0.id == id }), d.blocks[i].kind.isList { d.blocks[i].indent = min(6, max(0, d.blocks[i].indent + value)) } }
    }
    func add(_ kind: BlockKind, after: String? = nil, rows: Int = 3, columns: Int = 3) {
        var new = EditorBlock(kind: kind)
        if kind == .table { new.table = EditorTable(rows: min(100, max(1, rows)), columns: min(20, max(1, columns))) }
        mutate { d in
            let i = after.flatMap { id in d.blocks.firstIndex(where: { $0.id == id }) }.map { $0 + 1 } ?? d.blocks.count
            d.blocks.insert(new, at: i)
        }
        if kind != .table { focus(new.id) }
        else if let cell = new.table?.rows.first?.cells.first { focus(cell.id) }
    }
    func remove(_ id: String) { mutate { d in d.blocks.removeAll { $0.id == id }; if d.blocks.isEmpty { d.blocks = [EditorBlock()] } } }
    func updateTable(_ id: String, _ transform: (inout EditorTable) -> Void) {
        mutate { d in guard let i = d.blocks.firstIndex(where: { $0.id == id }), var table = d.blocks[i].table else { return }; transform(&table); d.blocks[i].table = table }
    }
    func setCell(table: String, row: String, column: String, value: String) {
        updateTable(table) { t in if let r = t.rows.firstIndex(where: { $0.id == row }), let c = t.columns.firstIndex(where: { $0.id == column }) { t.rows[r].cells[c].text = value } }
    }
    func row(_ block: String, before target: String? = nil, delete: String? = nil) {
        updateTable(block) { t in
            if let delete { if t.rows.count > 1 { t.rows.removeAll { $0.id == delete } }; return }
            let new = EditorRow(cells: t.columns.map { _ in EditorCell() })
            t.rows.insert(new, at: target.flatMap { id in t.rows.firstIndex(where: { $0.id == id }) } ?? t.rows.count)
        }
    }
    func column(_ block: String, before target: String? = nil, delete: String? = nil) {
        updateTable(block) { t in
            if let delete, let i = t.columns.firstIndex(where: { $0.id == delete }) {
                if t.columns.count > 1 { t.columns.remove(at: i); for r in t.rows.indices { t.rows[r].cells.remove(at: i) } }; return
            }
            let i = target.flatMap { id in t.columns.firstIndex(where: { $0.id == id }) } ?? t.columns.count
            t.columns.insert(EditorColumn(), at: i); for r in t.rows.indices { t.rows[r].cells.insert(EditorCell(), at: i) }
        }
    }
    func nextCell(table block: String, row: String, column: String, backwards: Bool) {
        guard let t = document.blocks.first(where: { $0.id == block })?.table,
              let r = t.rows.firstIndex(where: { $0.id == row }), let c = t.columns.firstIndex(where: { $0.id == column }) else { return }
        let index = r * t.columns.count + c + (backwards ? -1 : 1)
        guard index >= 0 else { return }
        if index >= t.rows.count * t.columns.count { self.row(block) }
        if let changed = document.blocks.first(where: { $0.id == block })?.table { focus(changed.rows[index / changed.columns.count].cells[index % changed.columns.count].id) }
    }
    @discardableResult func acceptDrop(_ payload: EditorDrag, on target: EditorDrop) -> Bool {
        var destination = target
        if case .cell(let block, let row, let column) = target {
            if payload.kind == "row" { destination = .row(block, row) }
            else if payload.kind == "column" { destination = .column(block, column) }
            else if payload.kind == "block" { destination = .block(block) }
        }
        let moved = drop(payload, on: destination)
        dragStatus = moved ? (payload.kind == "cell" ? "已交换单元格内容" : "已移动") : "位置未改变；请拖到同一副本中的对应目标"
        return moved
    }
    @discardableResult func drop(_ drag: EditorDrag, on target: EditorDrop) -> Bool {
        guard drag.document == document.id else { return false }
        switch target {
        case .block(let id):
            guard drag.kind == "block", let from = document.blocks.firstIndex(where: { $0.id == drag.block }), let to = document.blocks.firstIndex(where: { $0.id == id }), from != to else { return false }
            mutate { d in let item = d.blocks.remove(at: from); d.blocks.insert(item, at: to) }; return true
        case .row(let block, let row):
            guard drag.kind == "row", drag.block == block, let table = document.blocks.first(where: { $0.id == block })?.table,
                  let from = table.rows.firstIndex(where: { $0.id == drag.row }), let to = table.rows.firstIndex(where: { $0.id == row }), from != to else { return false }
            updateTable(block) { t in let item = t.rows.remove(at: from); t.rows.insert(item, at: to) }; return true
        case .column(let block, let col):
            guard drag.kind == "column", drag.block == block, let t = document.blocks.first(where: { $0.id == block })?.table,
                  let from = t.columns.firstIndex(where: { $0.id == drag.column }), let to = t.columns.firstIndex(where: { $0.id == col }), from != to else { return false }
            updateTable(block) { t in
                let item = t.columns.remove(at: from); t.columns.insert(item, at: to)
                for r in t.rows.indices { let cell = t.rows[r].cells.remove(at: from); t.rows[r].cells.insert(cell, at: to) }
            }; return true
        case .cell(let block, let row, let col):
            guard drag.kind == "cell", drag.block == block, let t = document.blocks.first(where: { $0.id == block })?.table,
                  let fr = t.rows.firstIndex(where: { $0.id == drag.row }), let fc = t.columns.firstIndex(where: { $0.id == drag.column }),
                  let tr = t.rows.firstIndex(where: { $0.id == row }), let tc = t.columns.firstIndex(where: { $0.id == col }), fr != tr || fc != tc else { return false }
            updateTable(block) { t in let cell = t.rows[fr].cells[fc]; t.rows[fr].cells[fc] = t.rows[tr].cells[tc]; t.rows[tr].cells[tc] = cell }; return true
        }
    }
}
/// Weak registration avoids retaining every editor window for the app lifetime.
@MainActor final class WeakEditor { weak var value: LocalEditor?; init(_ value: LocalEditor) { self.value = value } }
/// Tracks open models and strongly retains only sessions with unsaved changes.
@MainActor enum EditorRegistry { static var models: [WeakEditor] = []; static var unsaved: [LocalEditor] = [] }
/// Blocks termination while a recoverable local edit has not reached disk.
@MainActor final class EditorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let editors = EditorRegistry.models.compactMap(\.value)
        editors.forEach { $0.saveNow() }
        if editors.contains(where: { $0.dirty }) {
            let alert = NSAlert(); alert.messageText = "本地修改尚未保存"; alert.informativeText = "请返回编辑器查看保存错误，重试保存或复制未保存内容后再退出。"; alert.addButton(withTitle: "返回编辑器"); alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}
