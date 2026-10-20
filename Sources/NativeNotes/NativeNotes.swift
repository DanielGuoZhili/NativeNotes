import SwiftUI
import CoreData
import AppKit

/// Enables isolated fixtures through an argument or environment variable.
func isDemoLaunch() -> Bool { CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["NATIVENOTES_DEMO"] == "1" }

/// Core Data representation of a read-only source snapshot.
@objc(CachedNote) final class CachedNote: NSManagedObject, Identifiable {
    @NSManaged var sourceID: String
    @NSManaged var title: String
    @NSManaged var folder: String
    @NSManaged var text: String
    @NSManaged var html: String
    @NSManaged var sourceModified: Date?
    @NSManaged var importedAt: Date
}

/// Programmatic Core Data stack for imported source snapshots.
/// Local editable documents deliberately use a separate JSON store.
enum CacheStore {
    static let model: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "CachedNote"; entity.managedObjectClassName = NSStringFromClass(CachedNote.self)
        entity.properties = ["sourceID", "title", "folder", "text", "html", "sourceModified", "importedAt"].map { name in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = ["sourceModified", "importedAt"].contains(name) ? .dateAttributeType : .stringAttributeType
            attribute.isOptional = name == "sourceModified"
            return attribute
        }
        entity.uniquenessConstraints = [["sourceID"]]
        model.entities = [entity]
        return model
    }()
    static func open(at url: URL) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "NativeNotes", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }
    static func all(_ context: NSManagedObjectContext) throws -> [CachedNote] {
        try context.fetch(NSFetchRequest<CachedNote>(entityName: "CachedNote"))
    }
}

/// Coordinates Notes discovery, explicit selection, import and refresh operations.
@MainActor final class Workspace: ObservableObject {
    @Published var sources: [SourceNote] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var status = "尚未连接。点击“读取来源”选择要导入的笔记。"
    @Published var failures: [String] = []
    @Published var loaded = false
    @Published var folders: [String] = []
    let bridge = NotesBridge()
    let demo: Bool
    init(demo: Bool) { self.demo = demo }
    func load() async {
        busy = true; failures = []; status = "正在读取来源和附件数量，笔记较多时请稍候…"; defer { busy = false }
        do {
            if demo {
                sources = [SourceNote(id: "demo-1", title: "欢迎使用 NativeNotes", folder: "演示 / 工作", locked: false, attachmentCount: 0), SourceNote(id: "demo-2", title: "中文与多行正文", folder: "演示 / 生活", locked: false, attachmentCount: 8), SourceNote(id: "demo-locked", title: "受保护笔记", folder: "演示 / 生活", locked: true)]
            } else {
                let catalog = try await bridge.list()
                folders = Array(Set(catalog.map(\.folder))).sorted()
                sources = catalog.filter { !$0.folderOnly }
            }
            if demo { folders = Array(Set(sources.map(\.folder))).sorted() }
            selected.formIntersection(Set(sources.filter { !$0.locked }.map(\.id)))
            loaded = true
            status = sources.isEmpty ? "Apple Notes 未返回可见笔记。请确认已登录账户、已下载笔记，并重试。" : "已找到 \(sources.count) 篇笔记。勾选后点击“导入所选”。"
        } catch { failures = [error.localizedDescription]; status = "读取来源失败；本地缓存仍可查看。" }
    }
    func transfer(_ targets: [SourceNote], context: NSManagedObjectContext) async {
        busy = true; failures = []; defer { busy = false }
        var success = 0
        for (index, source) in targets.enumerated() {
            status = "正在读取 \(index + 1)/\(targets.count)：\(source.title)"
            do {
                let body: NoteBody
                if demo {
                    body = NoteBody(title: source.title, text: "\(source.title)\n\n这是独立演示数据，没有访问 Apple Notes。\n支持中文、换行和离线查看。\n读取时间：\(Date().formatted())", html: "<h1>格式化演示（非真实导入）</h1><h2>表格示例</h2><table><tr><th>事项</th><th>状态</th></tr><tr><td>中文内容</td><td>待处理</td></tr><tr><td>第二行</td><td>已核对</td></tr></table><h2>清单示例（已明确提供状态）</h2><ul><li><input type=\"checkbox\">未完成样例</li><li><input type=\"checkbox\" checked>已完成样例</li></ul><p>真实 Apple Notes 导入可能不提供这些勾选状态，不能从普通列表推断。</p>", modified: Date())
                } else { body = try await bridge.read(source.id) }
                let all = try CacheStore.all(context)
                if let cached = all.first(where: { $0.sourceID == source.id }) {
                    cached.title = body.title; cached.folder = source.folder; cached.text = body.text
                    cached.html = body.html; cached.sourceModified = body.modified; cached.importedAt = Date()
                } else {
                    let note = CachedNote(context: context)
                    note.sourceID = source.id; note.title = body.title; note.folder = source.folder
                    note.text = body.text; note.html = body.html; note.sourceModified = body.modified; note.importedAt = Date()
                }
                do { try context.save() } catch { context.rollback(); throw error }
                success += 1
            } catch { failures.append("\(source.title)：\(error.localizedDescription)") }
        }
        status = "完成：成功 \(success) 篇，失败 \(failures.count) 篇。失败项保留原有缓存。"
    }
    func refresh(_ cached: [CachedNote], context: NSManagedObjectContext) async {
        let imported = cached.filter { !$0.sourceID.hasPrefix("local:") }
        guard !imported.isEmpty else { status = "没有需要刷新的 Apple Notes 来源。本地笔记不参与来源刷新。"; return }
        await load()
        guard failures.isEmpty else { return }
        let lookup = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let unavailable = imported.filter { lookup[$0.sourceID] == nil || lookup[$0.sourceID]?.locked == true }
        let targets = imported.compactMap { lookup[$0.sourceID] }.filter { !$0.locked }
        await transfer(targets, context: context)
        failures += unavailable.map { "\($0.title)：源笔记不在可读列表中（可能删除、锁定或尚未下载），保留旧缓存。" }
        if !unavailable.isEmpty { status += "另有 \(unavailable.count) 篇不可读，已保留缓存。" }
    }
}

/// Root three-pane workspace and application-level commands.
struct MainView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \CachedNote.importedAt, ascending: false)]) private var cached: FetchedResults<CachedNote>
    @StateObject var workspace: Workspace
    @State private var viewing: String?
    private func createNote() {
        let note = CachedNote(context: context)
        note.sourceID = "local:" + UUID().uuidString
        note.title = "未命名笔记"; note.folder = "本地笔记"; note.text = ""; note.html = ""; note.importedAt = Date()
        do { try context.save(); viewing = note.sourceID }
        catch { context.rollback(); workspace.failures = [error.localizedDescription] }
    }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSplitView(
                revision: WorkspaceRevision(selected: viewing, notes: cached.map {
                    .init(id: $0.sourceID, title: $0.title, folder: $0.folder, preview: String($0.text.prefix(200)), importedAt: $0.importedAt)
                }),
                source: AnyView(SourceBrowser(workspace: workspace, importedIDs: Set(cached.map(\.sourceID))).environment(\.managedObjectContext, context)),
                library: AnyView(library.environment(\.managedObjectContext, context)),
                detail: AnyView(detail.environment(\.managedObjectContext, context))
            )
            Divider()
            HStack(spacing: 10) {
                if workspace.busy { ProgressView().controlSize(.mini) }
                Text(workspace.status).lineLimit(1).accessibilityIdentifier("status")
                Spacer()
                Text(workspace.demo ? "演示 · 0.4.0" : "0.4.0").foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
            if !workspace.failures.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ScrollView { VStack(alignment: .leading, spacing: 4) { ForEach(Array(workspace.failures.enumerated()), id: \.offset) { _, error in Text(error).foregroundStyle(.red).textSelection(.enabled) } } }.frame(maxHeight: 72)
                    Button("打开自动化权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 820, minHeight: 560)
        .navigationTitle("NativeNotes")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: createNote) { Label("新建笔记", systemImage: "square.and.pencil") }.help("新建本地笔记")
                Button { Task { await workspace.load() } } label: { Label("读取来源", systemImage: "folder.badge.gearshape") }.help("读取 Apple Notes 来源")
                Button {
                    let targets = workspace.sources.filter { workspace.selected.contains($0.id) && !$0.locked }
                    Task { await workspace.transfer(targets, context: context) }
                } label: { Label("导入所选（\(workspace.selected.count)）", systemImage: "square.and.arrow.down") }.disabled(workspace.selected.isEmpty).help("导入所选（\(workspace.selected.count)）")
                Button { Task { await workspace.refresh(Array(cached), context: context) } } label: { Label("刷新已导入", systemImage: "arrow.clockwise") }.disabled(cached.isEmpty).help("刷新已导入")
            }
        }.disabled(workspace.busy)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("本地笔记").font(.headline); Spacer(); Text("\(cached.count)").font(.caption).foregroundStyle(.secondary) }.padding(14)
            Divider()
            if cached.isEmpty {
                ContentUnavailableView("暂无本地笔记", systemImage: "note.text").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $viewing) {
                    ForEach(cached) { note in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title).font(.headline).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(note.importedAt, format: .dateTime.month().day())
                                Text(note.text.split(separator: "\n").dropFirst().first.map(String.init) ?? "本地副本").lineLimit(1)
                            }.font(.caption).foregroundStyle(.secondary)
                            Label(note.folder, systemImage: "folder").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }.padding(.vertical, 7).tag(note.sourceID)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private var detail: some View {
        if let note = cached.first(where: { $0.sourceID == viewing }) { NoteDetailView(note: note, workspace: workspace).id(note.sourceID) }
        else { ContentUnavailableView("选择笔记", systemImage: "note.text").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor)) }
    }
}

#if !SELF_TEST
/// Application entry point and shared persistence bootstrap.
@main struct NativeNotesApp: App {
    @NSApplicationDelegateAdaptor(EditorAppDelegate.self) private var appDelegate
    let container: NSPersistentContainer?
    let startupError: String?
    let demo = isDemoLaunch()
    init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("NativeNotes", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(isDemoLaunch() ? "Demo.store" : "Notes.store")
            container = try CacheStore.open(at: url)
            startupError = nil
        } catch { container = nil; startupError = error.localizedDescription }
    }
    var body: some Scene {
        WindowGroup {
            if let container { MainView(workspace: Workspace(demo: demo)).environment(\.managedObjectContext, container.viewContext) }
            else { VStack(spacing: 16) { Text("本地缓存无法打开").font(.title2); Text(startupError ?? "未知错误").textSelection(.enabled); Text("未清空或覆盖现有缓存。请检查磁盘空间及 ~/Library/Application Support/NativeNotes 的访问权限，修复后重新打开。") }.padding(40).frame(width: 640) }
        }.defaultSize(width: 1280, height: 800).windowToolbarStyle(.unifiedCompact)
    }
}

#endif
