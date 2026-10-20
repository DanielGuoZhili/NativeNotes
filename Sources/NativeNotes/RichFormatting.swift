import SwiftUI
import AppKit

/// Converts attributed content to optional RTF while retaining plain text as the source of truth.
enum RichTextCodec {
    static func decode(_ data: Data?, text: String) -> NSAttributedString? {
        guard let data, let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), value.string == text else { return nil }
        let result = NSMutableAttributedString(attributedString: value)
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let color = attributes[.foregroundColor] as? NSColor
            if attributes[.link] != nil {
                result.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            } else if color == nil || color == NSColor.black || color == NSColor.white {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return result
    }
    static func encode(_ value: NSAttributedString) -> Data? {
        try? value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    static func slice(_ data: Data?, text: String, range: NSRange) -> Data? {
        guard let value = decode(data, text: text), NSMaxRange(range) <= value.length else { return nil }
        return encode(value.attributedSubstring(from: range))
    }
    static func joined(_ first: EditorBlock, _ second: EditorBlock) -> Data? {
        guard first.richText != nil || second.richText != nil else { return nil }
        let fallback: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let value = NSMutableAttributedString(attributedString: decode(first.richText, text: first.text) ?? NSAttributedString(string: first.text, attributes: fallback))
        value.append(decode(second.richText, text: second.text) ?? NSAttributedString(string: second.text, attributes: fallback))
        return encode(value)
    }
    static func linkURL(_ input: String) -> URL? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme),
              let url = components.url else { return nil }
        if scheme == "mailto" {
            // Foundation versions disagree on whether a mailto recipient is exposed as
            // `path`; validate the scheme-specific text directly for deterministic CI.
            guard let separator = raw.firstIndex(of: ":"), !raw[raw.index(after: separator)...].isEmpty else { return nil }
        } else if components.host?.isEmpty ?? true { return nil }
        return url
    }
}

/// Inline traits exposed by the formatting toolbar.
enum InlineStyle { case bold, italic, underline, strike }

/// Routes toolbar actions to the currently focused NativeNotes text view.
@MainActor final class RichFormatContext: NSObject, ObservableObject {
    @Published private(set) var available = false
    private weak var view: EditorNativeTextView?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(beganEditing(_:)), name: NSText.didBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(beganEditing(_:)), name: Notification.Name("NativeNotesEditorFocused"), object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func beganEditing(_ note: Notification) {
        guard let editor = note.object as? EditorNativeTextView, editor.formatting === self else { view = nil; available = false; return }
        view = editor; available = true
    }
    private var target: EditorNativeTextView? {
        guard let view, view.window?.firstResponder === view, !view.hasMarkedText() else { return nil }
        return view
    }
    func toggle(_ style: InlineStyle) {
        guard let view = target else { return }
        let range = view.selectedRange()
        let fallback = view.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15)
        func enabled(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            switch style {
            case .bold, .italic:
                let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
                return NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? fallback).contains(trait)
            case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
            case .strike: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
        }
        var allEnabled = true
        if range.length == 0 { allEnabled = enabled(view.typingAttributes) }
        else { view.textStorage?.enumerateAttributes(in: range) { attributes, _, _ in allEnabled = allEnabled && enabled(attributes) } }
        let turnOn = !allEnabled
        func changed(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attributes
            switch style {
            case .bold, .italic:
                let font = attributes[.font] as? NSFont ?? fallback
                let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
                result[.font] = turnOn ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            case .underline, .strike:
                let key: NSAttributedString.Key = style == .underline ? .underlineStyle : .strikethroughStyle
                result[key] = turnOn ? NSUnderlineStyle.single.rawValue : 0
            }
            return result
        }
        if range.length == 0 { view.typingAttributes = changed(view.typingAttributes); return }
        guard view.shouldChangeText(in: range, replacementString: nil), let storage = view.textStorage else { return }
        let snapshot = storage.attributedSubstring(from: range)
        storage.beginEditing()
        snapshot.enumerateAttributes(in: NSRange(location: 0, length: snapshot.length)) { attributes, local, _ in
            storage.setAttributes(changed(attributes), range: NSRange(location: range.location + local.location, length: local.length))
        }
        storage.endEditing(); view.didChangeText(); view.setSelectedRange(range)
    }
    func align(_ alignment: NSTextAlignment) {
        guard let view = target else { return }
        let selection = view.selectedRange()
        let range = (view.string as NSString).paragraphRange(for: selection)
        guard range.length > 0, view.shouldChangeText(in: range, replacementString: nil), let storage = view.textStorage else { return }
        let snapshot = storage.attributedSubstring(from: range)
        snapshot.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: snapshot.length)) { value, local, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: range.location + local.location, length: local.length))
        }
        view.didChangeText(); view.setSelectedRange(selection)
    }
    private func transform(_ change: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let view = target else { return }
        let range = view.selectedRange()
        if range.length == 0 { view.typingAttributes = change(view.typingAttributes); return }
        guard view.shouldChangeText(in: range, replacementString: nil), let storage = view.textStorage else { return }
        let snapshot = storage.attributedSubstring(from: range)
        storage.beginEditing()
        snapshot.enumerateAttributes(in: NSRange(location: 0, length: snapshot.length)) { attrs, local, _ in
            storage.setAttributes(change(attrs), range: NSRange(location: range.location + local.location, length: local.length))
        }
        storage.endEditing(); view.didChangeText(); view.setSelectedRange(range)
    }
    func fontSize(_ size: CGFloat) {
        transform { attrs in
            var result = attrs
            result[.font] = NSFontManager.shared.convert(attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15), toSize: size)
            return result
        }
    }
    func fontFamily(_ family: String) {
        transform { attrs in
            var result = attrs
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15)
            result[.font] = NSFontManager.shared.convert(font, toFamily: family)
            return result
        }
    }
    func color(_ color: NSColor?, highlight: Bool = false) {
        transform { attrs in
            var result = attrs
            let key: NSAttributedString.Key = highlight ? .backgroundColor : .foregroundColor
            result[key] = color
            return result
        }
    }
    func clearFormatting() {
        transform { attrs in
            var result: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
            if let link = attrs[.link] { result[.link] = link; result[.foregroundColor] = NSColor.linkColor }
            return result
        }
    }
    func spacing(_ multiple: CGFloat) {
        guard let view = target else { return }
        let selection = view.selectedRange()
        view.setSelectedRange((view.string as NSString).paragraphRange(for: selection))
        transform { attrs in
            var result = attrs
            let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = multiple
            result[.paragraphStyle] = style
            return result
        }
        view.setSelectedRange(selection)
    }
    func insertLink() {
        guard let target = target else { return }
        let selection = target.selectedRange()
        let existing = (target.string as NSString).substring(with: selection)
        let alert = NSAlert(); alert.messageText = "插入链接"; alert.informativeText = "输入网页地址或 mailto: 地址。"
        let fields = NSStackView(); fields.orientation = .vertical; fields.spacing = 10
        let label = NSTextField(string: existing); label.placeholderString = "显示文字（可选）"
        let url = NSTextField(string: ""); url.placeholderString = "https://example.com"
        fields.alignment = .leading
        fields.addArrangedSubview(label); fields.addArrangedSubview(url)
        label.widthAnchor.constraint(equalToConstant: 320).isActive = true
        url.widthAnchor.constraint(equalToConstant: 320).isActive = true
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 62)
        alert.accessoryView = fields; alert.addButton(withTitle: "插入"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = url
        guard alert.runModal() == .alertFirstButtonReturn else { target.window?.makeFirstResponder(target); return }
        guard let address = RichTextCodec.linkURL(url.stringValue) else {
            let error = NSAlert(); error.messageText = "链接地址无效"; error.informativeText = "请使用完整的 http://、https:// 或 mailto: 地址。"; error.runModal(); target.window?.makeFirstResponder(target); return
        }
        let text = label.stringValue.isEmpty ? address.absoluteString : label.stringValue
        guard target.shouldChangeText(in: selection, replacementString: text) else { return }
        var attributes = target.typingAttributes
        attributes[.link] = address; attributes[.foregroundColor] = NSColor.linkColor; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        target.textStorage?.replaceCharacters(in: selection, with: NSAttributedString(string: text, attributes: attributes))
        target.didChangeText(); target.window?.makeFirstResponder(target)
        target.setSelectedRange(NSRange(location: selection.location + (text as NSString).length, length: 0))
        view = target; available = true
    }
}

/// Responsive formatting controls that collapse into menus in narrow layouts.
struct InlineFormattingTools: View {
    @ObservedObject var context: RichFormatContext
    @ViewBuilder private var styles: some View {
        Button("粗体", systemImage: "bold") { context.toggle(.bold) }.keyboardShortcut("b", modifiers: .command)
        Button("斜体", systemImage: "italic") { context.toggle(.italic) }.keyboardShortcut("i", modifiers: .command)
        Button("下划线", systemImage: "underline") { context.toggle(.underline) }.keyboardShortcut("u", modifiers: .command)
        Button("删除线", systemImage: "strikethrough") { context.toggle(.strike) }
    }
    @ViewBuilder private var alignment: some View {
        Button("左对齐", systemImage: "text.alignleft") { context.align(.left) }
        Button("居中", systemImage: "text.aligncenter") { context.align(.center) }
        Button("右对齐", systemImage: "text.alignright") { context.align(.right) }
        Button("两端对齐", systemImage: "text.justify") { context.align(.justified) }
    }
    @ViewBuilder private var richTools: some View {
        Menu("字号") {
            ForEach([12, 14, 15, 16, 18, 20, 24, 28, 32], id: \.self) { size in
                Button("\(size) 磅") { context.fontSize(CGFloat(size)) }
            }
        }
        Menu("字体") {
            Button("系统字体") { context.fontFamily(NSFont.systemFont(ofSize: 15).familyName ?? "Helvetica Neue") }
            Button("衬线字体") { context.fontFamily("Times New Roman") }
            Button("等宽字体") { context.fontFamily("Menlo") }
        }
        Menu("文字颜色") {
            Button("默认") { context.color(.labelColor) }
            Button("红色") { context.color(.systemRed) }
            Button("橙色") { context.color(.systemOrange) }
            Button("绿色") { context.color(.systemGreen) }
            Button("蓝色") { context.color(.systemBlue) }
            Button("紫色") { context.color(.systemPurple) }
        }
        Menu("高亮") {
            Button("无高亮") { context.color(nil, highlight: true) }
            Button("黄色") { context.color(NSColor.systemYellow.withAlphaComponent(0.35), highlight: true) }
            Button("绿色") { context.color(NSColor.systemGreen.withAlphaComponent(0.25), highlight: true) }
            Button("粉色") { context.color(NSColor.systemPink.withAlphaComponent(0.25), highlight: true) }
        }
        Menu("行距") {
            Button("紧凑") { context.spacing(1) }
            Button("1.25 倍") { context.spacing(1.25) }
            Button("1.5 倍") { context.spacing(1.5) }
            Button("2 倍") { context.spacing(2) }
        }
        Button("清除文字格式", systemImage: "textformat") { context.clearFormatting() }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ControlGroup {
                Menu { styles } label: { Image(systemName: "bold.italic.underline") }.menuIndicator(.hidden).help("选中文字的样式")
                Menu { richTools } label: { Image(systemName: "textformat.size") }.menuIndicator(.hidden).help("富文本：字体、字号、颜色、高亮和行距")
                Menu { alignment } label: { Image(systemName: "text.alignleft") }.menuIndicator(.hidden).help("段落对齐")
                Button { context.insertLink() } label: { Image(systemName: "link") }.help("插入链接")
            }
            Menu {
                Section("文字样式") { styles }
                Section("富文本") { richTools }
                Section("段落对齐") { alignment }
                Divider()
                Button("插入链接", systemImage: "link") { context.insertLink() }
            } label: { Image(systemName: "bold.italic.underline") }.menuIndicator(.hidden).help("文字样式、对齐与链接")
        }.disabled(!context.available)
    }
}
