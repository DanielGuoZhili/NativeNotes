import Foundation
import AppKit
import Combine

/// Regression checks for document editing, persistence, drag geometry and rich text.
@MainActor enum EditorChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeNotes-Editor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func make(_ id: String = UUID().uuidString, html: String = "", text: String = "") -> LocalEditor {
            LocalEditor(sourceID: id, title: "测试副本", html: html, text: text, directory: directory)
        }
        for (prefix, kind, expected) in [("1. ",BlockKind.numbered,"2."),("a. ",.lowerAlpha,"b."),("A. ",.upperAlpha,"B."),("i. ",.lowerRoman,"ii."),("I. ",.upperRoman,"II."),("z. ",.lowerAlpha,"aa.")] {
            let editor = make(), id = editor.document.blocks[0].id
            editor.setText(id, prefix + "第一项")
            try check(editor.document.blocks[0].kind == kind && editor.document.blocks[0].text == "第一项", "typed \(prefix) converts to expected list")
            editor.enter(id, range: NSRange(location: 3, length: 0))
            try check(editor.document.blocks.count == 2 && editor.document.blocks[1].marker == expected && editor.focus?.id == editor.document.blocks[1].id, "return continues \(prefix) as \(expected) and requests focus")
        }
        let taskID = UUID().uuidString
        let task = LocalEditor(sourceID: taskID, title: "任务列表", html: "<h1>任务列表</h1><p><br/></p><ul><li>甲</li><li>乙</li><li>丙</li></ul>", text: "", directory: directory)
        try check(task.document.blocks.count == 3 && task.document.blocks.allSatisfy { $0.kind == .todo && $0.todo == .open }, "confirmed task note has check circles without duplicate title or spacer rows")
        let originalIDs = task.document.blocks.map(\.id)
        task.toggleTodo(originalIDs[0])
        task.moveBlocks(from: IndexSet(integer: 0), to: 3)
        try check(task.document.blocks.map(\.id) == [originalIDs[1], originalIDs[2], originalIDs[0]] && task.document.blocks.last?.todo == .done, "native list move downward preserves task identity and completion")
        task.moveBlocks(from: IndexSet(integer: 2), to: 0)
        try check(task.document.blocks.map(\.id) == originalIDs, "native list move upward uses insertion offset correctly")
        let reopenedTask = LocalEditor(sourceID: taskID, title: "任务列表", html: "", text: "", directory: directory)
        try check(reopenedTask.document.blocks.first?.todo == .done && reopenedTask.document.taskPresentation == 1, "task presentation migration is persistent and preserves checked state on reopen")
        let live = CardReorder()
        for (i, b) in task.document.blocks.enumerated() { live.frames[b.id] = CGRect(x: 0, y: i * 50, width: 400, height: 44) }
        live.update(originalIDs[0], dy: 105, blocks: task.document.blocks)
        try check(live.order == [originalIDs[1], originalIDs[2], originalIDs[0]] && task.document.blocks.map(\.id) == originalIDs, "live drag previews reordered cards without saving intermediate positions")
        live.cancel()
        try check(live.active == nil && live.blocks(task.document.blocks).map(\.id) == originalIDs, "cancel live drag restores original order")
        task.reorderBlocks([originalIDs[1], originalIDs[2], originalIDs[0]])
        task.undo()
        try check(task.document.blocks.map(\.id) == originalIDs, "completed live drag is a single undoable change")
        let cursorBounds = CGRect(x: 0, y: 0, width: 400, height: 30)
        try check(CursorGeometry.clipped(CGRect(x: 0, y: 100, width: 100, height: 20), to: cursorBounds) == nil, "offscreen text never registers a null cursor rectangle")
        try check(CursorGeometry.clipped(.null, to: cursorBounds) == nil && CursorGeometry.clipped(.infinite, to: cursorBounds) == nil, "nonfinite cursor geometry is rejected")
        try check(CursorGeometry.clipped(.zero, to: cursorBounds) == nil && CursorGeometry.clipped(cursorBounds, to: .zero) == nil, "unlaid-out zero size views never register cursor rectangles")
        try check(CursorGeometry.clipped(CGRect(x: 10, y: 20, width: 600, height: 20), to: cursorBounds) == CGRect(x: 10, y: 20, width: 390, height: 10), "partially visible text cursor rectangle is clipped safely")
        let smooth = CardReorder()
        let many = (0..<150).map { EditorBlock(kind: .todo, text: "性能验证 \($0)") }
        for (i, b) in many.enumerated() { smooth.frames[b.id] = CGRect(x: 0, y: i * 50, width: 400, height: 44) }
        smooth.update(many[0].id, dy: 0, blocks: many)
        var documentUpdates = 0, movingUpdates = 0, otherUpdates = 0
        let a = smooth.objectWillChange.sink { documentUpdates += 1 }
        let b = smooth.motion(for: many[0].id).objectWillChange.sink { movingUpdates += 1 }
        let c = smooth.motion(for: many[1].id).objectWillChange.sink { otherUpdates += 1 }
        for tick in 1...1000 { smooth.update(many[0].id, dy: CGFloat(tick % 10), blocks: many) }
        try check(documentUpdates == 0 && movingUpdates > 0 && otherUpdates == 0, "1000 drag ticks update only the moving card, not the 150-row document or other cards")
        withExtendedLifetime((a, b, c)) {}
        let benchmarkStart = ProcessInfo.processInfo.systemUptime
        for tick in 1...10000 { smooth.update(many[0].id, dy: CGFloat(tick % 10), blocks: many) }
        print(String(format: "DRAG BENCH: 150 rows / 10000 movement updates: %.2f ms (model only, not display FPS)", (ProcessInfo.processInfo.systemUptime - benchmarkStart) * 1000))
        let beforeCrossing = documentUpdates
        smooth.update(many[0].id, dy: 80, blocks: many)
        try check(documentUpdates == beforeCrossing && smooth.order.first != many[0].id, "crossing slots updates row motion without rebuilding document or text editors")
        smooth.cancel()
        let held = CardReorder()
        let heldBlocks = (0..<3).map { EditorBlock(kind: .todo, text: "按住验证 \($0)") }
        let fixedFrames = Dictionary(uniqueKeysWithValues: heldBlocks.enumerated().map { ($0.element.id, CGRect(x: 0, y: $0.offset * 50, width: 400, height: 44)) })
        held.frames = fixedFrames
        held.update(heldBlocks[0].id, dy: 5, blocks: heldBlocks)
        held.frames[heldBlocks[0].id] = fixedFrames[heldBlocks[0].id]!.offsetBy(dx: 0, dy: 5)
        held.refreshMotion()
        try check(held.motion(for: heldBlocks[0].id).y == 5, "held row stays at mouse position after transformed geometry callback, rather than snapping back")
        var follows = true, monotonic = true, lastIndex = 0
        for pixel in 6...130 {
            held.frames = fixedFrames.mapValues { $0.offsetBy(dx: 0, dy: CGFloat(pixel % 2 == 0 ? 80 : -30)) }
            held.update(heldBlocks[0].id, dy: CGFloat(pixel), blocks: heldBlocks)
            held.refreshMotion()
            follows = follows && held.motion(for: heldBlocks[0].id).y == CGFloat(pixel)
            let index = held.order.firstIndex(of: heldBlocks[0].id)!
            monotonic = monotonic && index >= lastIndex; lastIndex = index
        }
        try check(follows && monotonic, "held slow downward pixel sweep never reverses or flickers despite animated geometry feedback")
        let stableOrder = held.order
        for _ in 0..<500 { held.update(heldBlocks[0].id, dy: 130, blocks: heldBlocks); held.refreshMotion() }
        try check(held.order == stableOrder && held.motion(for: heldBlocks[0].id).y == 130, "holding mouse still for 500 layout callbacks preserves row position and destination")
        for pixel in stride(from: 129, through: 0, by: -1) { held.update(heldBlocks[0].id, dy: CGFloat(pixel), blocks: heldBlocks) }
        try check(held.order == heldBlocks.map(\.id) && held.motion(for: heldBlocks[0].id).y == 0, "slow upward reverse drag returns to original slot without geometry jumps")
        held.cancel()
        let measured = TextMeasureCache()
        let sample = String(repeating: "中文内容与 URL https://example.com 测试🙂 ", count: 4)
        var sizesMatch = true
        for heading in [false, true] {
            for width in [CGFloat(156), 240, 420, 650] {
                let font = NSFont.systemFont(ofSize: heading ? 21 : 15, weight: heading ? .semibold : .regular)
                let storage = NSTextStorage(string: sample, attributes: [.font: font])
                let manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                manager.addTextContainer(container); storage.addLayoutManager(manager); manager.ensureLayout(for: container)
                let expected = max(24, ceil(manager.usedRect(for: container).height) + 8)
                let actual = measured.height(text: sample, heading: heading, width: width)
                sizesMatch = sizesMatch && actual >= expected - 1 && actual <= expected + 2
            }
        }
        try check(sizesMatch, "cached resize measurement agrees with native TextKit for multiline Chinese, emoji, URLs and heading fonts")
        let extremeWidths: [CGFloat] = [.infinity, -.infinity, .nan, 0, -1, .greatestFiniteMagnitude]
        try check(extremeWidths.allSatisfy {
            measured.height(text: sample, heading: false, width: $0).isFinite
        }, "SwiftUI unbounded, NaN and extreme width probes cannot crash text measurement")
        let firstHeight = measured.height(text: sample, heading: false, width: 400)
        let initialCalculations = measured.calculationCount
        for _ in 0..<1000 { _ = measured.height(text: sample, heading: false, width: 400) }
        try check(measured.calculationCount == initialCalculations, "repeated resize proposals reuse cached height instead of relaying out the live editor")
        let editedHeight = measured.height(text: sample + sample, heading: false, width: 400)
        try check(editedHeight > firstHeight, "text edits invalidate resize measurement cache and grow the editor")
        let richEditor = make(text: "样式测试🙂文字")
        let richID = richEditor.document.blocks[0].id
        let richString = NSMutableAttributedString(string: richEditor.document.blocks[0].text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        richString.addAttributes([.font: NSFont.boldSystemFont(ofSize: 15), .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 0, length: 4))
        richString.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 4, length: 2))
        let richData = RichTextCodec.encode(richString)!
        richEditor.setRichText(richID, text: richString.string, richText: richData)
        let storedRichDocument = try JSONDecoder().decode(EditorDocument.self, from: Data(contentsOf: richEditor.file))
        let decodedRich = RichTextCodec.decode(storedRichDocument.blocks[0].richText, text: richString.string)!
        try check(NSFontManager.shared.traits(of: decodedRich.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.boldFontMask) && (decodedRich.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int) == 1, "bold and underline survive local JSON/RTF save and reload")
        try check(decodedRich.attribute(.link, at: 4, effectiveRange: nil) != nil && decodedRich.string == richString.string, "rich text preserves explicit link and Unicode content")
        richEditor.enter(richID, range: NSRange(location: 2, length: 0))
        try check(richEditor.document.blocks.allSatisfy { RichTextCodec.decode($0.richText, text: $0.text) != nil }, "Return splits styled paragraph while preserving attributes in both pieces")
        let afterSplit = richEditor.document.blocks[1].id
        richEditor.backspace(afterSplit)
        try check(richEditor.document.blocks.count == 1 && RichTextCodec.decode(richEditor.document.blocks[0].richText, text: richString.string)?.string == richString.string, "Backspace joins styled paragraphs without losing text or formatting")
        richEditor.undo()
        try check(richEditor.document.blocks.count == 2 && richEditor.document.blocks[0].richText != nil, "undo restores styled paragraph structure")
        try check(RichTextCodec.linkURL("https://example.com") != nil && RichTextCodec.linkURL("mailto:hello@example.com") != nil && RichTextCodec.linkURL("javascript:alert(1)") == nil && RichTextCodec.linkURL("not a url") == nil, "link insertion accepts web/mail links and rejects invalid or executable schemes")
        let largeRich = NSAttributedString(string: sample, attributes: [.font: NSFont.systemFont(ofSize: 30)])
        try check(measured.height(text: sample, heading: false, width: 240, richText: RichTextCodec.encode(largeRich)) > measured.height(text: sample, heading: false, width: 240), "width measurement respects persisted rich text font sizes")
        let spaced = NSMutableParagraphStyle(); spaced.lineHeightMultiple = 1.5
        let colored = NSAttributedString(string: "彩色文字", attributes: [.font: NSFont(name: "Menlo", size: 24)!, .foregroundColor: NSColor.systemRed, .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35), .paragraphStyle: spaced])
        let restoredColor = RichTextCodec.decode(RichTextCodec.encode(colored), text: colored.string)!
        let restoredForeground = (restoredColor.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).usingColorSpace(.deviceRGB)!
        try check(restoredForeground.redComponent > restoredForeground.greenComponent, "explicit rich text color survives RTF reload")
        try check(restoredColor.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil && (restoredColor.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 24, "highlight and custom font size survive RTF reload")
        try check(abs((restoredColor.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle).lineHeightMultiple - 1.5) < 0.02, "custom line spacing survives RTF reload")
        let roman = make(), romanID = roman.document.blocks[0].id
        roman.setText(romanID, "i. 一"); roman.enter(romanID, range: NSRange(location: 1, length: 0))
        let second = roman.document.blocks[1].id
        roman.setText(second, "二"); roman.enter(second, range: NSRange(location: 1, length: 0))
        try check(roman.document.blocks[2].marker == "iii.", "Roman list continues through iii")
        let empty = roman.document.blocks[2].id
        roman.enter(empty, range: NSRange(location: 0, length: 0))
        try check(roman.document.blocks[2].kind == .paragraph, "return on empty list exits list")
        roman.indent(second, by: 1)
        try check(roman.document.blocks[1].indent == 1, "Tab indentation changes list level")
        let emoji = make(text: "🙂中文")
        emoji.enter(emoji.document.blocks[0].id, range: NSRange(location: 2, length: 0))
        try check(emoji.document.blocks.map(\.text) == ["🙂", "中文"], "UTF-16 caret splits emoji without corruption")
        let imported = make(html: "<ul><li>没有状态</li><li>也是没有状态</li></ul>")
        try check(imported.document.blocks.filter { $0.kind == .bullet }.count == 2 && !imported.document.blocks.contains { $0.kind == .todo }, "imported ordinary lists do not invent todo state")
        imported.convertListsToTodos()
        try check(imported.document.blocks.filter { $0.kind == .todo }.allSatisfy { $0.todo == .unknown }, "converting source lists marks todo state unknown")
        let todo = imported.document.blocks.first { $0.kind == .todo }!
        imported.toggleTodo(todo.id)
        try check(imported.document.blocks.first { $0.id == todo.id }?.todo == .done, "explicit click resolves todo to locally completed")
        imported.toggleTodo(todo.id)
        try check(imported.document.blocks.first { $0.id == todo.id }?.todo == .open, "completed todo can become incomplete")
        let lastID = imported.document.blocks.last!.id
        let moved = imported.drop(EditorDrag(document: imported.document.id, kind: "block", block: todo.id), on: .block(lastID))
        try check(moved && imported.document.blocks.last?.id == todo.id, "todo blocks reorder using drag payload")
        let tableEditor = make()
        tableEditor.add(.table, rows: 2, columns: 2)
        let blockID = tableEditor.document.blocks.last!.id
        var table = tableEditor.document.blocks.last!.table!
        tableEditor.setCell(table: blockID, row: table.rows[0].id, column: table.columns[0].id, value: "A🙂")
        tableEditor.setCell(table: blockID, row: table.rows[1].id, column: table.columns[1].id, value: "B中文")
        _ = tableEditor.drop(EditorDrag(document: tableEditor.document.id, kind: "cell", block: blockID, row: table.rows[0].id, column: table.columns[0].id), on: .cell(blockID, table.rows[1].id, table.columns[1].id))
        table = tableEditor.document.blocks.last!.table!
        try check(table.rows[0].cells[0].text == "B中文" && table.rows[1].cells[1].text == "A🙂", "cell drag swaps content without losing Unicode")
        let originalFirstRow = table.rows[0].id
        _ = tableEditor.drop(EditorDrag(document: tableEditor.document.id, kind: "row", block: blockID, row: originalFirstRow), on: .row(blockID, table.rows[1].id))
        table = tableEditor.document.blocks.last!.table!
        try check(table.rows[1].id == originalFirstRow && table.rows[1].cells[0].text == "B中文", "row drag preserves row data")
        let originalFirstColumn = table.columns[0].id
        _ = tableEditor.drop(EditorDrag(document: tableEditor.document.id, kind: "column", block: blockID, column: originalFirstColumn), on: .column(blockID, table.columns[1].id))
        table = tableEditor.document.blocks.last!.table!
        try check(table.columns[1].id == originalFirstColumn && table.rows[1].cells[1].text == "B中文", "column drag reorders cells in every row")
        tableEditor.row(blockID); tableEditor.column(blockID)
        table = tableEditor.document.blocks.last!.table!
        try check(table.rows.count == 3 && table.columns.count == 3 && table.rows.allSatisfy { $0.cells.count == 3 }, "adding rows and columns keeps rectangular table")
        let beforeUndo = tableEditor.document
        tableEditor.undo()
        try check(tableEditor.document.blocks.last!.table!.columns.count == 2, "structural edit can be undone")
        tableEditor.redo()
        try check(tableEditor.document.blocks == beforeUndo.blocks, "structural edit can be redone")
        let wrong = tableEditor.drop(EditorDrag(document: "another-document", kind: "block", block: blockID), on: .block(tableEditor.document.blocks[0].id))
        try check(!wrong, "cross-document drag payload cannot alter note")
        let persisted = make("persisted", text: "来源原文")
        let persistentID = persisted.document.blocks[0].id
        persisted.setText(persistentID, "本地更改")
        let sourceChanged = make("persisted", text: "新的来源原文")
        try check(sourceChanged.document.blocks[0].text == "本地更改" && sourceChanged.document.sourceHash != DocumentImporter.hash("", "新的来源原文"), "reopening with new source retains independent local edits")
        persisted.setText(persistentID, "第一窗口的新内容")
        sourceChanged.setText(persistentID, "第二窗口的修改")
        try check(sourceChanged.dirty && sourceChanged.saveError != nil && make("persisted").document.blocks[0].text == "第一窗口的新内容", "conflicting window cannot overwrite newer disk revision")
        let retained = LocalEditor.open(sourceID: "persisted", title: "测试", html: "", text: "", directory: directory)
        try check(retained === sourceChanged && retained.document.blocks[0].text == "第二窗口的修改", "failed save stays available when reopening note")
        let corrupted = make("corrupt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid-json".utf8).write(to: corrupted.file)
        let failed = make("corrupt")
        failed.setText(failed.document.blocks[0].id, "不应覆盖")
        try check(failed.loadError != nil && String(data: try Data(contentsOf: failed.file), encoding: .utf8) == "invalid-json", "corrupt edit file is reported and preserved")
        let htmlTable = make(html: "<table><tr><th>列A</th><th>列B</th></tr><tr><td>值1</td><td>值2</td></tr></table>")
        let parsedTable = htmlTable.document.blocks.first { $0.kind == .table }?.table
        try check(parsedTable?.rows.count == 2 && parsedTable?.columns.count == 2 && parsedTable?.rows[1].cells[1].text == "值2", "provided HTML table imports as editable cells")
    }
}
