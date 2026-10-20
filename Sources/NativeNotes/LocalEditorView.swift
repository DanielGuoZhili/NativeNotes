import SwiftUI
import QuartzCore

/// Accepts typed drag payloads and delegates validated mutations to `LocalEditor`.
struct EditorDropZone: ViewModifier {
    @ObservedObject var editor: LocalEditor
    let target: EditorDrop
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).background(targeted ? Color.accentColor.opacity(0.12) : .clear)
            .onDrop(of: [EditorDrag.type, "public.data"], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                editor.dragStatus = "正在放置…"
                let type = provider.hasItemConformingToTypeIdentifier(EditorDrag.type) ? EditorDrag.type : "public.data"
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data, let payload = try? JSONDecoder().decode(EditorDrag.self, from: data) else { return }
                    Task { @MainActor in
                        var destination = target
                        if case .cell(let block, let row, let column) = target {
                            if payload.kind == "row" { destination = .row(block, row) }
                            else if payload.kind == "column" { destination = .column(block, column) }
                            else if payload.kind == "block" { destination = .block(block) }
                        }
                        let moved = withAnimation(.smooth(duration: 0.25)) { editor.drop(payload, on: destination) }
                        editor.dragStatus = moved ? (payload.kind == "cell" ? "已交换单元格内容" : "已移动") : "位置未改变；请拖到同一副本中的对应目标"
                    }
                }
                return true
            }
    }
}

/// Complete local editing surface: toolbar, title, blocks, tables and todo reordering.
struct LocalEditorView: View {
    @StateObject private var editor: LocalEditor
    let sourceHash: String
    let titleChanged: ((String) -> Void)?
    @StateObject private var reorder = CardReorder()
    @State private var formatting = RichFormatContext()
    @State private var rows = 3
    @State private var columns = 3
    @State private var creatingTable = false
    init(sourceID: String, title: String, html: String, text: String, demo: Bool, titleChanged: ((String) -> Void)? = nil) {
        self.titleChanged = titleChanged
        sourceHash = DocumentImporter.hash(html, text)
        _editor = StateObject(wrappedValue: LocalEditor.open(sourceID: sourceID, title: title, html: html, text: text, directory: LocalEditor.directory(demo: demo)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ControlGroup {
                    Menu {
                        Section("文字") {
                            Button("正文", systemImage: "text.alignleft") { editor.add(.paragraph) }
                            Button("标题", systemImage: "textformat.size") { editor.add(.heading) }
                        }
                        Section("列表") {
                            ForEach([BlockKind.bullet, .numbered, .lowerAlpha, .upperAlpha, .lowerRoman, .upperRoman]) { kind in
                                Button(listStyleName(kind), systemImage: kind == .bullet ? "list.bullet" : "list.number") { editor.add(kind) }
                            }
                        }
                    } label: { Image(systemName: "textformat") }.menuIndicator(.hidden).help("文字与列表格式")
                    Button { editor.add(.todo) } label: { Image(systemName: "checklist") }.help("插入待办").accessibilityIdentifier("addTodo")
                    Button { creatingTable = true } label: { Image(systemName: "tablecells") }.help("插入表格").accessibilityIdentifier("createTable")
                        .popover(isPresented: $creatingTable) {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("插入表格", systemImage: "tablecells").font(.headline)
                                Stepper("\(rows) 行", value: $rows, in: 1...100)
                                Stepper("\(columns) 列", value: $columns, in: 1...20)
                                Button("插入") { editor.add(.table, rows: rows, columns: columns); creatingTable = false }.buttonStyle(.borderedProminent)
                            }.padding(20).frame(width: 210)
                        }
                }.controlGroupStyle(.automatic)
                InlineFormattingTools(context: formatting)
                Divider().frame(height: 18)
                HStack(spacing: 12) {
                    Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(editor.undoStack.isEmpty).help("撤销")
                    Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(editor.redoStack.isEmpty).help("重做")
                }
                Spacer(minLength: 0)
                Text(editor.dirty ? "未保存" : "已保存").font(.caption2).foregroundStyle(editor.dirty ? .orange : .secondary).lineLimit(1)
                Menu {
                    Button("项目符号转为待办") { editor.convertListsToTodos() }
                    Button("全部列表转为待办") { editor.convertListsToTodos(all: true) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多编辑操作")
            }.buttonStyle(.borderless).font(.system(size: 16)).padding(.horizontal, 18).padding(.vertical, 8)
                .background(.bar).disabled(editor.loadError != nil)
            Divider()
            if editor.document.sourceHash != sourceHash {
                Text("来源已更新，本地副本仍保留你的编辑。可切换“来源预览”对照最新快照。").font(.caption).foregroundStyle(.orange)
            }
            if let error = editor.loadError {
                Text("本地副本无法读取，已停止编辑，未覆盖文件：\(error)").foregroundStyle(.red).textSelection(.enabled)
            } else {
                if let error = editor.saveError {
                    HStack { Text("未保存：\(error)").foregroundStyle(.red).textSelection(.enabled); Button("重试保存") { editor.saveNow() }; Button("另存完整副本") { editor.saveRecoveryCopy() } }.font(.caption)
                }
                TextField("本地副本标题", text: Binding(get: { editor.document.title }, set: { editor.setTitle($0); titleChanged?($0) }))
                    .font(.system(size: 24, weight: .bold)).textFieldStyle(.plain).accessibilityIdentifier("localDocumentTitle")
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(editor.document.blocks) { block in
                                blockView(block).id(block.id)
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: CardFrames.self, value: [block.id: geometry.frame(in: .named("cards"))])
                                    })
                                    .modifier(MovingCardPosition(motion: reorder.motion(for: block.id), tracking: reorder.active == block.id))
                                    .transition(.identity)
                                    .shadow(color: .black.opacity(reorder.active == block.id ? 0.16 : 0), radius: 6, y: 3)
                                    .zIndex(reorder.active == block.id ? 10 : 0)
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 4)
                        .coordinateSpace(name: "cards")
                        .onPreferenceChange(CardFrames.self) { if reorder.active == nil { reorder.frames = $0 } }
                    }
                    .accessibilityIdentifier("localEditorCanvas")
                        .onChange(of: editor.focus?.token) { _, _ in
                            if let focus = editor.focus, let blockID = editor.blockID(for: focus.id) {
                                DispatchQueue.main.async { proxy.scrollTo(blockID, anchor: .center) }
                            }
                        }
                }
            }
        }
        .onDisappear { reorder.cancel(); editor.saveNow() }
    }
    private func listStyleName(_ kind: BlockKind) -> String {
        switch kind {
        case .bullet: return "项目符号列表"
        case .numbered: return "编号列表"
        case .lowerAlpha: return "小写字母列表"
        case .upperAlpha: return "大写字母列表"
        case .lowerRoman: return "小写罗马数字"
        case .upperRoman: return "大写罗马数字"
        default: return kind.title
        }
    }
    private func moveCard(_ id: String, dy: CGFloat, ended: Bool, cancelled: Bool) {
        if cancelled { withAnimation(.snappy(duration: 0.22)) { reorder.cancel() }; return }
        reorder.update(id, dy: dy, blocks: editor.document.blocks)
        if ended {
            let ids = reorder.order
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { editor.reorderBlocks(ids); reorder.cancel() }
        }
    }
    @ViewBuilder private func blockView(_ block: EditorBlock) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if block.kind == .table, let table = block.table {
                EditorTableView(editor: editor, blockID: block.id, table: table)
            } else {
                if block.kind == .todo {
                    Button { editor.toggleTodo(block.id) } label: {
                        Image(systemName: block.todo == .done ? "checkmark.circle.fill" : block.todo == .unknown ? "questionmark.circle" : "circle")
                            .font(.system(size: 20)).foregroundStyle(block.todo == .done ? Color.orange : Color.secondary)
                    }.buttonStyle(.plain).frame(width: 26, height: 30)
                        .help(block.todo == .unknown ? "状态待确认；点击后标记为本地已完成" : "切换本地完成状态")
                        .accessibilityLabel(block.todo == .unknown ? "待办状态待确认" : block.todo == .done ? "待办已完成" : "待办未完成")
                } else if block.kind.isList {
                    Text(block.marker).font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .trailing).padding(.top, 5)
                }
                EditorTextInput(id: block.id, text: block.text, heading: block.kind == .heading, focus: editor.focus,
                                changed: { editor.setText(block.id, $0) }, newline: { editor.enter(block.id, range: $0) },
                                backspace: { editor.backspace(block.id) }, tab: { editor.indent(block.id, by: $0 ? -1 : 1) },
                                dropped: { payload in withAnimation(.smooth(duration: 0.25)) { editor.acceptDrop(payload, on: .block(block.id)) } },
                                richText: block.richText, richChanged: { editor.setRichText(block.id, text: $0, richText: $1) }, formatting: formatting)
                    .frame(maxWidth: .infinity)
                if block.kind == .todo {
                    TodoGrip { dy, ended, cancelled in moveCard(block.id, dy: dy, ended: ended, cancelled: cancelled) }
                        .frame(width: 28, height: 30)
                        .help("拖动调整顺序")
                        .accessibilityIdentifier("todoGrip-" + block.id)
                }
            }
        }
        .padding(.leading, CGFloat(block.indent) * 18)
        .padding(.horizontal, 12)
        .padding(.vertical, block.kind == .todo ? 7 : block.kind == .heading ? 6 : 2)
        .background {
            if block.kind == .todo {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(block.kind == .todo ? 0.18 : 0), lineWidth: 1)
        }
        .modifier(EditorDropZone(editor: editor, target: .block(block.id)))
        .contextMenu {
                if block.kind != .table {
                    ForEach(BlockKind.allCases.filter { $0 != .table }) { kind in Button(kind.title) { editor.setKind(block.id, kind) } }
                    Divider()
                    Button("在下方插入待办") { editor.add(.todo, after: block.id) }
                    Button("在下方插入正文") { editor.add(.paragraph, after: block.id) }
                }
                Button("删除此内容块") { editor.remove(block.id) }
        }
    }
}

/// Editable table UI with row/column reordering and cell-content swapping.
struct EditorTableView: View {
    @ObservedObject var editor: LocalEditor
    let blockID: String
    let table: EditorTable
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(table.rows.count) 行 × \(table.columns.count) 列").font(.caption).foregroundStyle(.secondary)
                Button("＋行") { editor.row(blockID) }
                Button("＋列") { editor.column(blockID) }
            }.controlSize(.small)
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Color.clear.frame(width: 34, height: 25)
                        ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                            NativeDragHandle(editor: editor, kind: "column", block: blockID, column: column.id, title: ListRules.alpha(index + 1)).frame(width: 160, height: 25)
                                .background(Color.secondary.opacity(0.10)).border(Color.secondary.opacity(0.2))
                                .modifier(EditorDropZone(editor: editor, target: .column(blockID, column.id)))
                                .contextMenu {
                                    Button("在左侧插入列") { editor.column(blockID, before: column.id) }
                                    Button("删除此列") { editor.column(blockID, delete: column.id) }.disabled(table.columns.count == 1)
                                }
                                .accessibilityLabel("拖动第 \(index + 1) 列")
                        }
                    }
                    ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
                        GridRow(alignment: .top) {
                            NativeDragHandle(editor: editor, kind: "row", block: blockID, row: row.id, title: "\(index + 1)").frame(width: 34, height: 34)
                                .background(Color.secondary.opacity(0.10))
                                .modifier(EditorDropZone(editor: editor, target: .row(blockID, row.id)))
                                .contextMenu {
                                    Button("在上方插入行") { editor.row(blockID, before: row.id) }
                                    Button("删除此行") { editor.row(blockID, delete: row.id) }.disabled(table.rows.count == 1)
                                }
                                .accessibilityLabel("拖动第 \(index + 1) 行")
                            ForEach(Array(table.columns.enumerated()), id: \.element.id) { col, column in
                                HStack(alignment: .top, spacing: 2) {
                                    EditorTextInput(id: row.cells[col].id, text: row.cells[col].text, focus: editor.focus,
                                                    changed: { editor.setCell(table: blockID, row: row.id, column: column.id, value: $0) },
                                                    tab: { editor.nextCell(table: blockID, row: row.id, column: column.id, backwards: $0) },
                                                    dropped: { editor.acceptDrop($0, on: .cell(blockID, row.id, column.id)) })
                                    NativeDragHandle(editor: editor, kind: "cell", block: blockID, row: row.id, column: column.id).frame(width: 18, height: 24)
                                        .help("拖到另一单元格以交换内容")
                                }
                                .padding(5).frame(width: 160, alignment: .topLeading)
                                .frame(minHeight: 40)
                                .border(Color.secondary.opacity(0.3))
                                .modifier(EditorDropZone(editor: editor, target: .cell(blockID, row.id, column.id)))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Reports stable card geometry only while no drag is active.
private struct CardFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

/// Coordinates live todo-card movement while deferring document mutation until mouse-up.
@MainActor final class CardReorder: ObservableObject {
    @Published var active: String?
    private(set) var order: [String] = []
    var translation: CGFloat = 0
    private var motions: [String: CardMotion] = [:]
    func motion(for id: String) -> CardMotion {
        if let motion = motions[id] { return motion }
        let motion = CardMotion(); motions[id] = motion; return motion
    }
    var frames: [String: CGRect] = [:]
    private var origin: CGRect = .zero
    private var baseline: [String: CGRect] = [:]
    private var initialOrder: [String] = []
    private var otherIDs: [String] = []
    private var midpoints: [CGFloat] = []
    private var insertionIndex = -1
    private var placementDirty = false
    func blocks(_ source: [EditorBlock]) -> [EditorBlock] { source }
    func offset(_ id: String) -> CGFloat { motion(for: id).y }
    func update(_ id: String, dy: CGFloat, blocks: [EditorBlock]) {
        if active == nil {
            guard let frame = frames[id], blocks.allSatisfy({ frames[$0.id] != nil }) else { return }
            baseline = frames; initialOrder = blocks.map(\.id)
            origin = frame; order = initialOrder
            otherIDs = initialOrder.filter { $0 != id }
            midpoints = otherIDs.compactMap { baseline[$0]?.midY }
            insertionIndex = initialOrder.firstIndex(of: id) ?? 0
            placementDirty = false; active = id
        }
        guard active == id else { return }
        translation = dy
        // Positions are measured once at pickup. Animated/translated geometry is never input.
        let center = origin.midY + dy
        var lower = 0, upper = midpoints.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if midpoints[middle] < center { lower = middle + 1 } else { upper = middle }
        }
        if lower != insertionIndex {
            insertionIndex = lower; order = otherIDs; order.insert(id, at: lower); placementDirty = true
        }
        refreshMotion()
    }
    func refreshMotion() {
        guard let active else { return }
        let moving = motion(for: active)
        if moving.y != translation { moving.y = translation }
        guard placementDirty else { return }
        placementDirty = false
        var y = initialOrder.first.flatMap { baseline[$0]?.minY } ?? 0
        for id in order {
            guard let frame = baseline[id] else { continue }
            let value = id == active ? translation : y - frame.minY
            let item = motion(for: id)
            if item.y != value { item.y = value }
            y += frame.height + 6
        }
    }
    func cancel() {
        for motion in motions.values where motion.y != 0 { motion.y = 0 }
        active = nil; order = []; translation = 0; baseline = [:]; initialOrder = []
        otherIDs = []; midpoints = []; insertionIndex = -1; placementDirty = false
    }
}

/// AppKit bridge for the dedicated todo drag handle.
private struct TodoGrip: NSViewRepresentable {
    var move: (CGFloat, Bool, Bool) -> Void
    func makeNSView(context: Context) -> TodoGripView {
        let view = TodoGripView()
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("拖动待办排序")
        return view
    }
    func updateNSView(_ view: TodoGripView, context: Context) { view.move = move }
}
/// Converts raw mouse events into display-synchronized reorder updates.
private final class TodoGripView: NSView {
    var move: ((CGFloat, Bool, Bool) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        image?.draw(in: NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16))
    }
    override func resetCursorRects() { if let rect = CursorGeometry.clipped(bounds, to: bounds) { addCursorRect(rect, cursor: .openHand) } }
    private var link: CADisplayLink?
    private let tickTarget = GripDisplayTarget()
    private var pendingY: CGFloat?
    private var start: NSPoint?
    private var moving = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; moving = false; window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let dy = start.y - event.locationInWindow.y
        guard moving || hypot(event.locationInWindow.x - start.x, dy) >= 4 else { return }
        NSCursor.closedHand.set()
        if !moving {
            moving = true; move?(dy, false, false)
            tickTarget.view = self
            let display = displayLink(target: tickTarget, selector: #selector(GripDisplayTarget.tick(_:)))
            let maximum = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            display.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            display.add(to: .main, forMode: .common); link = display
        } else { pendingY = dy }
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }; self.start = nil
        stopDisplayUpdates()
        if moving { move?(start.y - event.locationInWindow.y, true, false) }; moving = false; NSCursor.openHand.set()
    }
    func displayTick() {
        guard moving, let y = pendingY else { return }
        pendingY = nil; move?(y, false, false)
    }
    private func stopDisplayUpdates() { link?.invalidate(); link = nil; pendingY = nil }
    override func cancelOperation(_ sender: Any?) { stopDisplayUpdates(); start = nil; moving = false; move?(0, true, true) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayUpdates(); if moving { move?(0, true, true) }; start = nil; moving = false }
    }
    deinit { link?.invalidate() }
}

/// Objective-C callback target retained for the lifetime of the display link.
private final class GripDisplayTarget: NSObject {
    weak var view: TodoGripView?
    @objc func tick(_ sender: CADisplayLink) { view?.displayTick() }
}

/// Isolates per-card motion so pointer updates do not invalidate the whole document.
@MainActor final class CardMotion: ObservableObject { @Published var y: CGFloat = 0 }
/// Applies immediate movement to the held card and animated displacement to neighboring cards.
private struct MovingCardPosition: ViewModifier {
    @ObservedObject var motion: CardMotion
    let tracking: Bool
    func body(content: Content) -> some View {
        content.offset(y: motion.y).animation(tracking ? nil : .snappy(duration: 0.18, extraBounce: 0), value: motion.y)
    }
}
