import SwiftUI
import AppKit

/// Native drag source used by table rows, columns and cells.
struct NativeDragHandle: NSViewRepresentable {
    @ObservedObject var editor: LocalEditor
    let kind: String
    let block: String
    var row: String? = nil
    var column: String? = nil
    var title: String? = nil
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ view: DragHandleView, context: Context) {
        view.editor = editor
        view.payload = EditorDrag(document: editor.document.id, kind: kind, block: block, row: row, column: column)
        view.title = title
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(title.map { "拖动 " + $0 } ?? (kind == "cell" ? "拖动单元格" : "拖动内容块"))
        view.registerForDraggedTypes([NSPasteboard.PasteboardType(EditorDrag.type)])
        view.needsDisplay = true
    }
}

/// Starts a local-only AppKit drag session with a typed, document-scoped payload.
final class DragHandleView: NSView, NSDraggingSource {
    weak var editor: LocalEditor?
    var payload: EditorDrag?
    var title: String?
    override func draw(_ dirtyRect: NSRect) {
        if let title {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
            let height = (title as NSString).size(withAttributes: attributes).height
            (title as NSString).draw(in: NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height), withAttributes: attributes)
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1
            for dy in [-3.0, 0.0, 3.0] { path.move(to: NSPoint(x: bounds.midX - 5, y: bounds.midY + dy)); path.line(to: NSPoint(x: bounds.midX + 5, y: bounds.midY + dy)) }
            path.stroke()
        }
    }
    private func incoming(_ sender: NSDraggingInfo) -> EditorDrag? {
        guard let data = sender.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(EditorDrag.type)),
              let drag = try? JSONDecoder().decode(EditorDrag.self, from: data), drag.document == editor?.document.id else { return nil }
        return drag
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { incoming(sender) == nil ? [] : .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { incoming(sender) == nil ? [] : .move }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { incoming(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let incoming = incoming(sender), let payload, let editor else { return false }
        let destination: EditorDrop
        if payload.kind == "row", let row = payload.row { destination = .row(payload.block, row) }
        else if payload.kind == "column", let column = payload.column { destination = .column(payload.block, column) }
        else if payload.kind == "cell", let row = payload.row, let column = payload.column { destination = .cell(payload.block, row, column) }
        else { destination = .block(payload.block) }
        return editor.acceptDrop(incoming, on: destination)
    }
    override func mouseDown(with event: NSEvent) {
        guard let payload, let data = try? JSONEncoder().encode(payload) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(EditorDrag.type))
        item.setData(data, forType: NSPasteboard.PasteboardType("public.data"))
        let drag = NSDraggingItem(pasteboardWriter: item)
        let preview = NSImage(size: bounds.size)
        preview.lockFocus(); draw(bounds); preview.unlockFocus()
        drag.setDraggingFrame(bounds, contents: preview)
        editor?.dragStatus = payload.kind == "cell" ? "拖动单元格：放到另一格交换内容" : payload.kind == "row" ? "拖动行：放到目标行" : payload.kind == "column" ? "拖动列：放到目标列" : "拖动内容：放到目标位置"
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty { editor?.dragStatus = "未移动：已取消或未落到可接收位置" }
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
