import SwiftUI
import WebKit
import AppKit

/// Produces a locked-down HTML document for read-only source preview.
enum RichDocument {
    static func containsList(_ html: String) -> Bool {
        html.range(of: "<(ul|ol|li)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func containsEmbeddedContent(_ html: String) -> Bool {
        html.range(of: "<(object|embed|iframe|img)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func html(_ fragment: String) -> String {
        // Source HTML remains a local read-only snapshot. Never load remote assets or scripts.
        let readOnly = fragment.replacingOccurrences(of: "<input\\b", with: "<input disabled", options: [.regularExpression, .caseInsensitive])
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        html { background: Canvas; color: CanvasText; }
        body { margin: 18px 20px 36px; font: 15px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
        h1 { font-size: 22px; line-height: 1.35; } h2 { font-size: 21px; } h3 { font-size: 18px; }
        h1,h2,h3 { margin: 0.8em 0 0.45em; } ul,ol { padding-left: 1.7em; } li { margin: 0.2em 0; }
        table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; margin: 12px 0; }
        td,th { border: 1px solid GrayText; padding: 8px 12px; vertical-align: top; min-width: 70px; }
        th { font-weight: 600; } pre { white-space: pre-wrap; } code,pre { font-family: ui-monospace, monospace; }
        blockquote { margin-left: 0; padding-left: 14px; border-left: 3px solid GrayText; }
        img { max-width: 100%; height: auto; } a { color: LinkText; } input { pointer-events: none; }
        </style></head><body>\(readOnly)</body></html>
        """
    }
}

/// WKWebView adapter used only for rendering the sanitized source snapshot.
struct RichHTMLView: NSViewRepresentable {
    let html: String
    @Binding var loadError: String?
    func makeCoordinator() -> Coordinator { Coordinator(error: $loadError) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        view.loadHTMLString(RichDocument.html(html), baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var error: Binding<String?>
        init(error: Binding<String?>) { self.error = error }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            // Only our in-memory document can navigate inside this viewer.
            decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { error.wrappedValue = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { error.wrappedValue = failure.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
            if (failure as NSError).code != NSURLErrorCancelled { error.wrappedValue = failure.localizedDescription }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error.wrappedValue = "格式化查看进程已退出，请切换来源纯文本查看或重新选择笔记。" }
    }
}

/// Switches between local editing, formatted source preview and source plain text.
struct NoteDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var note: CachedNote
    @ObservedObject var workspace: Workspace
    @State private var mode = 0
    @State private var opening = false
    @State private var openError: String?
    @State private var renderError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(note.folder).lineLimit(1)
                Spacer()
                Text((note.sourceModified ?? note.importedAt).formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                Menu {
                    Picker("查看方式", selection: $mode) {
                        Text("编辑本地副本").tag(0)
                        Text("来源预览").tag(1)
                        Text("来源纯文本").tag(2)
                    }
                    Divider()
                    Button("在备忘录中打开原文", systemImage: "arrow.up.forward.app") {
                        opening = true; openError = nil
                        Task {
                            defer { opening = false }
                            do { try await workspace.bridge.show(note.sourceID) }
                            catch { openError = error.localizedDescription }
                        }
                    }.disabled(workspace.demo || opening || note.sourceID.hasPrefix("local:"))
                    Divider()
                    Text("缓存时间：\(note.importedAt.formatted())")
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("笔记与来源")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
            if let openError { Text(openError).font(.caption).foregroundStyle(.red) }
            Divider()
            if mode == 0 {
                LocalEditorView(sourceID: note.sourceID, title: note.title, html: note.html, text: note.text, demo: workspace.demo, titleChanged: { title in
                    guard note.sourceID.hasPrefix("local:") else { return }
                    note.title = title
                    do { try context.save() } catch { context.rollback(); openError = error.localizedDescription }
                })
            } else if mode == 2 || note.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renderError != nil {
                if let renderError { Text("格式化查看失败，已显示纯文本：\(renderError)").font(.caption).foregroundStyle(.red) }
                ScrollView { Text(note.text.isEmpty ? "（空正文）" : note.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                RichHTMLView(html: note.html, loadError: $renderError).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}
