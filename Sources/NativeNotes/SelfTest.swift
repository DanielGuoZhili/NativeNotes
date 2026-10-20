import Foundation
import CoreData
import AppKit

/// Runs deterministic checks with temporary storage and demo data only.
/// No test in this suite requests access to the user's Apple Notes library.
@MainActor enum SelfTest {
    static func run() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeNotes-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            var checks = 0
            func check(_ condition: Bool, _ message: String) throws {
                if !condition { throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
                print("PASS: \(message)")
            }
            try check(NotesBridge.literal("a\"b\\c") == "\"a\\\"b\\\\c\"", "AppleScript ID escaping")
            try check(NotesFailure(code: -1743, detail: "").localizedDescription.contains("自动化"), "permission recovery message")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Test.store")
            let container = try CacheStore.open(at: url)
            let context = container.viewContext
            let workspace = Workspace(demo: true)
            await workspace.load()
            try check(workspace.sources.count == 3, "demo catalog")
            let target = workspace.sources.first { $0.id == "demo-1" }!
            await workspace.transfer([target], context: context)
            try check(workspace.failures.isEmpty && (try CacheStore.all(context)).count == 1, "selective import")
            await workspace.transfer([target], context: context)
            try check((try CacheStore.all(context)).count == 1, "reimport updates without duplicates")
            let reopened = try CacheStore.open(at: url)
            let notes = try CacheStore.all(reopened.viewContext)
            try check(notes.count == 1 && notes[0].text.contains("中文"), "persistent cache reopened with Unicode body")
            await workspace.refresh(notes, context: reopened.viewContext)
            try check(workspace.failures.isEmpty, "refresh imported only")
            let missing = CachedNote(context: reopened.viewContext)
            missing.sourceID = "missing"; missing.title = "旧缓存"; missing.folder = "已删除来源"; missing.text = "保留正文"; missing.html = ""; missing.importedAt = Date()
            try reopened.viewContext.save()
            await workspace.refresh([missing], context: reopened.viewContext)
            try check(!workspace.failures.isEmpty && missing.text == "保留正文", "unavailable source preserves old cache")
            let fixture = [
                SourceNote(id: "text", title: "NativeNotes 设计", folder: "iCloud / 工作", locked: false, attachmentCount: 0),
                SourceNote(id: "image", title: "照片", folder: "iCloud / 生活", locked: false, attachmentCount: 4),
                SourceNote(id: "backup", title: "备份", folder: "iCloud / 工作", locked: false, attachmentCount: 5),
                SourceNote(id: "locked", title: "加密", folder: "iCloud / 工作", locked: true),
                SourceNote(id: "unknown", title: "待下载", folder: "iCloud / 生活", locked: false)
            ]
            let importedIDs: Set<String> = ["text"]
            var filter = SourceFilter()
            func ids() -> Set<String> { Set(fixture.filter { filter.matches($0, importedIDs: importedIDs) }.map(\.id)) }
            try check(ids().count == 5, "default filters include all source notes")
            filter.query = "  nativenotes   工作  "
            try check(ids() == ["text"], "search combines case-insensitive title and folder keywords")
            filter.query = "不存在的词"
            try check(ids().isEmpty, "unmatched search has zero results")
            filter = SourceFilter(); filter.attachments = .none
            try check(ids() == ["text"], "no-attachment filter excludes unknown metadata")
            filter.attachments = .some
            try check(ids() == ["image", "backup"], "attachment filter includes positive counts")
            filter.attachments = .many
            try check(ids() == ["backup"], "many attachments threshold includes 5 and excludes 4")
            filter.attachments = .unknown
            try check(ids() == ["locked", "unknown"], "locked and failed attachment metadata remain unknown")
            filter = SourceFilter(); filter.folder = "iCloud / 工作"; filter.imported = .notImported; filter.access = .readable
            try check(ids() == ["backup"], "folder import and access filters intersect")
            filter = SourceFilter(); filter.imported = .imported
            try check(ids() == ["text"], "imported filter uses stable source identity")
            filter = SourceFilter(); filter.access = .locked
            try check(ids() == ["locked"], "protected-note filter")
            filter = SourceFilter(); filter.query = " \n "
            try check(!filter.isActive && ids().count == 5, "whitespace query behaves as reset")
            let table = "<table><tr><th>事项</th><th>状态</th></tr><tr><td>中文</td><td>待核对</td></tr></table>"
            try check(RichDocument.html(table).contains(table), "HTML table structure is retained for formatted viewing")
            let listHTML = "<ul><li>没有状态的列表</li></ul>"
            try check(RichDocument.containsList(listHTML) && !RichDocument.html(listHTML).contains("<input"), "ordinary imported lists never invent checkbox state")
            let checkbox = RichDocument.html("<input type=\"checkbox\" checked>")
            try check(checkbox.contains("<input disabled") && checkbox.contains("checked"), "provided checkbox state is retained and read-only")
            try check(RichDocument.containsEmbeddedContent("<OBJECT data=\"cid:table\"></OBJECT>"), "embedded objects trigger fidelity warning")
            try check(RichDocument.html(table).contains("default-src 'none'") && RichDocument.html(table).contains("form-action 'none'"), "formatted document blocks external assets and forms")
            try EditorChecks.run(check)
            print("SELF-TEST PASSED (\(checks) checks; no real Notes access)")
            exit(0)
        } catch { print("SELF-TEST FAILED: \(error.localizedDescription)"); exit(1) }
    }
}

#if SELF_TEST
/// Standalone entry point compiled only by `verify.sh`.
@main struct ValidationRunner {
    static func main() async { await SelfTest.run() }
}
#endif
