import SwiftUI
import AppKit

struct EditorTextInput: NSViewRepresentable {
    let id: String
    let text: String
    var heading = false
    let focus: EditorFocus?
    let changed: (String) -> Void
    var newline: ((NSRange) -> Bool)? = nil
    var backspace: (() -> Bool)? = nil
    var tab: ((Bool) -> Void)? = nil
    var dropped: ((EditorDrag) -> Bool)? = nil
    var richText: Data? = nil
    var richChanged: ((String, Data?) -> Void)? = nil
    var formatting: RichFormatContext? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextView {
        let view = EditorNativeTextView(frame: .zero)
        view.registerForDraggedTypes([NSPasteboard.PasteboardType(EditorDrag.type)])
        view.dropHandler = dropped
        view.isRichText = true
        view.importsGraphics = false
        let font = NSFont.systemFont(ofSize: heading ? 21 : 15, weight: heading ? .semibold : .regular)
        view.font = font; view.textColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        view.isEditable = true; view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 3)
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = true
        view.isContinuousSpellCheckingEnabled = false
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("editor-text-" + id)
        view.setAccessibilityLabel(heading ? "标题内容" : "编辑内容")
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if let native = view as? EditorNativeTextView {
            native.dropHandler = dropped
            native.formatting = formatting

        }
        if view.hasMarkedText() { return }
        if view.string != text || context.coordinator.loadedRTF != richText {
            let old = view.string as NSString, selected = view.selectedRange()
            if let styled = RichTextCodec.decode(richText, text: text) { view.textStorage?.setAttributedString(styled) }
            else { view.string = text; view.font = NSFont.systemFont(ofSize: heading ? 21 : 15, weight: heading ? .semibold : .regular); view.textColor = .labelColor }
            context.coordinator.loadedRTF = richText
            let delta = (text as NSString).length - old.length
            view.setSelectedRange(NSRange(location: max(0, min((text as NSString).length, selected.location + delta)), length: 0))
            context.coordinator.decorate(view)
            view.window?.invalidateCursorRects(for: view)
        } else if richText == nil && view.font?.pointSize != (heading ? 21 : 15) {
            let font = NSFont.systemFont(ofSize: heading ? 21 : 15, weight: heading ? .semibold : .regular)
            view.font = font; view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
            context.coordinator.decorate(view)
        }
        if let focus, focus.id == id, context.coordinator.focusToken != focus.token {
            context.coordinator.focusToken = focus.token
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: min(focus.cursor, (view.string as NSString).length), length: 0))
                view.scrollRangeToVisible(view.selectedRange())
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let fallback = nsView.bounds.width.isFinite && nsView.bounds.width > 0 ? nsView.bounds.width : 500
        let width = max(40, TextMeasureCache.safeWidth(proposal.width ?? fallback, fallback: fallback))
        let measuredText = nsView.hasMarkedText() ? nsView.string : text
        let height = context.coordinator.measurements.height(text: measuredText, heading: heading, width: width - 4, richText: richText)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextInput
        let measurements = TextMeasureCache()
        var loadedRTF: Data?
        var focusToken: UUID?
        var decorating = false
        init(_ parent: EditorTextInput) { self.parent = parent }
        func decorate(_ view: NSTextView) {
            guard !decorating && !view.hasMarkedText() else { return }
            decorating = true; defer { decorating = false }
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            let font = parent.heading ? NSFont.systemFont(ofSize: 21, weight: .semibold) : NSFont.systemFont(ofSize: 15)
            if view.typingAttributes[.font] == nil { view.typingAttributes[.font] = font }
            if view.typingAttributes[.foregroundColor] == nil { view.typingAttributes[.foregroundColor] = NSColor.labelColor }
            view.textStorage?.beginEditing()
            if let storage = view.textStorage {
                let snapshot = NSAttributedString(attributedString: storage)
                snapshot.enumerateAttributes(in: range) { attributes, subrange, _ in
                    if attributes[.font] == nil { storage.addAttribute(.font, value: font, range: subrange) }
                    if attributes[.foregroundColor] == nil { storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: subrange) }
                }
            }
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                for match in detector.matches(in: view.string, range: range) {
                    if let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                        view.textStorage?.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
                    }
                }
            }
            view.textStorage?.endEditing()
        }
        func textDidChange(_ notification: Notification) {
            guard !decorating, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            decorate(view)
            if let changed = parent.richChanged {
                let data = RichTextCodec.encode(view.attributedString()); loadedRTF = data
                changed(view.string, data)
            } else { parent.changed(view.string) }
            view.invalidateIntrinsicContentSize()
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:":
                if NSEvent.modifierFlags.contains(.shift) { return false }
                return parent.newline?(textView.selectedRange()) ?? false
            case "deleteBackward:":
                if textView.selectedRange().location == 0 && textView.selectedRange().length == 0 { return parent.backspace?() ?? false }
                return false
            case "insertTab:": if let tab = parent.tab { tab(false); return true }; return false
            case "insertBacktab:": if let tab = parent.tab { tab(true); return true }; return false
            default: return false
            }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return true
        }
    }
}

final class EditorNativeTextView: NSTextView {
    weak var formatting: RichFormatContext?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { NotificationCenter.default.post(name: Notification.Name("NativeNotesEditorFocused"), object: self) }
        return accepted
    }
    var dropHandler: ((EditorDrag) -> Bool)?
    private func incoming(_ sender: NSDraggingInfo) -> EditorDrag? {
        guard let data = sender.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(EditorDrag.type)) else { return nil }
        return try? JSONDecoder().decode(EditorDrag.self, from: data)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if incoming(sender) != nil { return dropHandler == nil ? [] : .move }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if incoming(sender) != nil { return dropHandler == nil ? [] : .move }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if incoming(sender) != nil { return dropHandler != nil }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let payload = incoming(sender) { return dropHandler?(payload) ?? false }
        return super.performDragOperation(sender)
    }
}

enum CursorGeometry {
    static func clipped(_ rect: NSRect, to bounds: NSRect) -> NSRect? {
        func finite(_ value: NSRect) -> Bool {
            [value.origin.x, value.origin.y, value.width, value.height].allSatisfy(\.isFinite) && !value.isEmpty && !value.isNull && !value.isInfinite
        }
        guard finite(rect), finite(bounds) else { return nil }
        let visible = rect.intersection(bounds)
        return finite(visible) ? visible : nil
    }
}

/// Layout proposals must never mutate the live editor. A proposal may be speculative
/// and SwiftUI can ask for several widths before choosing the actual view frame.
final class TextMeasureCache {
    private var source: String?
    private var isHeading = false
    private var styledSource: Data?
    private var attributed = NSAttributedString(string: "")
    private var heights: [Int: CGFloat] = [:]
    private(set) var calculationCount = 0
    static func safeWidth(_ value: CGFloat, fallback: CGFloat = 500) -> CGFloat {
        let finite = value.isFinite && value > 0 ? value : fallback
        return min(100_000, max(1, finite.isFinite && finite > 0 ? finite : 500))
    }
    func height(text: String, heading: Bool, width: CGFloat, richText: Data? = nil) -> CGFloat {
        if source != text || isHeading != heading || styledSource != richText {
            source = text; isHeading = heading; styledSource = richText; heights.removeAll(keepingCapacity: true)
            let font = NSFont.systemFont(ofSize: heading ? 21 : 15, weight: heading ? .semibold : .regular)
            let value = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
            attributed = RichTextCodec.decode(richText, text: text) ?? NSAttributedString(string: value, attributes: [.font: font])
        }
        let key = max(1, Int((Self.safeWidth(width) * 2).rounded(.down)))
        if let height = heights[key] { return height }
        let rect = attributed.boundingRect(with: NSSize(width: CGFloat(key) / 2, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = max(24, ceil(rect.height) + 8)
        // Keep a small cache while dragging back and forth without retaining every width.
        if heights.count >= 32 { heights.removeAll(keepingCapacity: true) }
        heights[key] = height; calculationCount += 1
        return height
    }
}
