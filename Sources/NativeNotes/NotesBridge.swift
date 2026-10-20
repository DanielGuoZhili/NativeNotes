import Foundation
import AppKit
import Carbon

struct SourceNote: Identifiable, Sendable {
    let id: String
    let title: String
    let folder: String
    let locked: Bool
    var folderOnly: Bool = false
    var attachmentCount: Int? = nil
}
struct NoteBody: Sendable { let title: String; let text: String; let html: String; let modified: Date? }
struct NotesFailure: LocalizedError {
    let code: Int
    let detail: String
    var errorDescription: String? {
        switch code {
        case -1743: return "系统尚未允许访问 Apple Notes（-1743）。如果自动化列表有 NativeNotes，请开启备忘录；如果没有，说明授权请求未登记，请退出旧版，从 Finder 直接打开新版再点读取来源。若仍无提示，请将本错误反馈给开发者，不需要开启完全磁盘访问。"
        case -1744: return "系统需要你确认自动化权限。请从 Finder 打开 NativeNotes 并再次点击读取来源。"
        case -600: return "Apple Notes 尚未运行。请先打开备忘录，再点击读取来源。"
        case -1712: return "备忘录响应超时。请打开 Apple Notes，等待内容下载完成后重试。旧缓存已保留。"
        case -1728: return "源笔记已删除、移动或暂时不可用。旧缓存已保留；请刷新来源列表后重新选择。"
        default: return "Apple Notes 读取失败（\(code)）：\(detail)"
        }
    }
}
final class NotesBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NativeNotes.AppleScript", qos: .userInitiated)
    @MainActor private func startNotes() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Notes.app"), configuration: configuration)
    }
    private func requestPermission() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // Explicitly allow macOS to prompt; never treat a missing Settings row as consent.
                let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), true)
                if status == noErr { continuation.resume() }
                else { continuation.resume(throwing: NotesFailure(code: Int(status), detail: "请求访问 com.apple.Notes 时返回系统错误")) }
            }
        }
    }
    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private func execute<T: Sendable>(_ source: String, decode: @escaping (NSAppleEventDescriptor) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                autoreleasepool {
                    var error: NSDictionary?
                    guard let script = NSAppleScript(source: source) else {
                        continuation.resume(throwing: NotesFailure(code: -1, detail: "无法创建脚本")); return
                    }
                    let result = script.executeAndReturnError(&error)
                    if let error {
                        continuation.resume(throwing: NotesFailure(code: (error[NSAppleScript.errorNumber] as? Int) ?? -1, detail: error[NSAppleScript.errorMessage] as? String ?? "未知错误"))
                    } else {
                        do { continuation.resume(returning: try decode(result)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
    func list() async throws -> [SourceNote] {
        try await startNotes()
        try await requestPermission()
        return try await execute("""
        on scanFolder(theFolder, parentPath)
            tell application "/System/Applications/Notes.app"
                set folderPath to parentPath & " / " & («property pnam» of theFolder)
                set rows to {{«property ID  » of theFolder, "", folderPath, false, true, -1}}
                repeat with n in (get every «class note» of theFolder)
                    set isLocked to «property pwpr» of n
                    set attachmentTotal to -1
                    if not isLocked then
                        try
                            set attachmentTotal to count (get every «class atts» of n)
                        end try
                    end if
                    set end of rows to {«property ID  » of n, «property pnam» of n, folderPath, isLocked, false, attachmentTotal}
                end repeat
                repeat with childFolder in (get every «class cfol» of theFolder)
                    set rows to rows & my scanFolder(childFolder, folderPath)
                end repeat
                return rows
            end tell
        end scanFolder
        with timeout of 90 seconds
            tell application "/System/Applications/Notes.app"
                set rows to {}
                repeat with a in (get every «class acct»)
                    repeat with f in (get every «class cfol» of a)
                        set rows to rows & my scanFolder(f, «property pnam» of a)
                    end repeat
                end repeat
                return rows
            end tell
        end timeout
        """) { result in
            var notes: [SourceNote] = []
            var seen = Set<String>()
            for i in 0..<result.numberOfItems {
                guard let row = result.atIndex(i + 1), row.numberOfItems == 6,
                      let id = row.atIndex(1)?.stringValue,
                      let title = row.atIndex(2)?.stringValue,
                      let folder = row.atIndex(3)?.stringValue else { throw NotesFailure(code: -2, detail: "来源列表格式异常") }
                let count = row.atIndex(6)?.int32Value ?? -1
                if seen.insert(id).inserted { notes.append(SourceNote(id: id, title: title, folder: folder, locked: row.atIndex(4)?.booleanValue ?? true, folderOnly: row.atIndex(5)?.booleanValue ?? false, attachmentCount: count >= 0 ? Int(count) : nil)) }
            }
            return notes.sorted { ($0.folder, $0.title) < ($1.folder, $1.title) }
        }
    }
    func show(_ id: String) async throws {
        try await startNotes()
        try await requestPermission()
        _ = try await execute("""
        with timeout of 30 seconds
            tell application "/System/Applications/Notes.app"
                activate
                «event noteshow» («class note» id \(Self.literal(id)))
                return true
            end tell
        end timeout
        """) { $0.booleanValue }
    }
    func read(_ id: String) async throws -> NoteBody {
        try await execute("""
        with timeout of 30 seconds
            tell application "/System/Applications/Notes.app"
                set n to «class note» id \(Self.literal(id))
                if «property pwpr» of n then error "此笔记受密码保护，第一版不导入。" number -2700
                return {«property pnam» of n, «property text» of n, «property body» of n, «property asmo» of n}
            end tell
        end timeout
        """) { result in
            guard result.numberOfItems == 4, let title = result.atIndex(1)?.stringValue,
                  let text = result.atIndex(2)?.stringValue, let html = result.atIndex(3)?.stringValue else {
                throw NotesFailure(code: -2, detail: "正文格式异常，未覆盖缓存")
            }
            return NoteBody(title: title, text: text, html: html, modified: result.atIndex(4)?.dateValue)
        }
    }
}
