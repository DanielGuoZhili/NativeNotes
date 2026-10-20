import SwiftUI
import AppKit

/// AppKit owns divider tracking and width restoration; SwiftUI owns each pane's contents.
struct WorkspaceSplitView: NSViewControllerRepresentable {
    let revision: WorkspaceRevision
    let source: AnyView
    let library: AnyView
    let detail: AnyView
    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        WorkspaceSplitController(contents: [source, library, detail], revision: revision)
    }
    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.update(contents: [source, library, detail], revision: revision)
    }
}
final class WorkspaceSplitController: NSSplitViewController {
    let hosts: [NSHostingController<AnyView>]
    private var placed = false
    private var revision: WorkspaceRevision
    private(set) var rootReplacementCount = 0
    func update(contents: [AnyView], revision next: WorkspaceRevision) {
        guard revision != next else { return }
        revision = next
        zip(hosts, contents).forEach { $0.0.rootView = $0.1; rootReplacementCount += 1 }
    }
    init(contents: [AnyView], revision: WorkspaceRevision) {
        self.revision = revision
        hosts = contents.map {
            let host = NSHostingController(rootView: $0)
            // Split items already provide the size limits; do not repeatedly ask SwiftUI
            // for min/ideal/max sizes while AppKit is tracking a divider.
            host.sizingOptions = []
            return host
        }
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "NativeNotesWorkspaceV3"
        for (index, host) in hosts.enumerated() {
            let item = NSSplitViewItem(viewController: host)
            item.minimumThickness = index == 2 ? 340 : 180
            item.canCollapse = false
            item.holdingPriority = NSLayoutConstraint.Priority(index == 2 ? 250 : 260)
            addSplitViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        let hitArea = rect.isEmpty ? drawnRect : rect
        return hitArea.insetBy(dx: -4, dy: 0)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !placed else { return }; placed = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames NativeNotesWorkspaceV3") == nil {
            let width = splitView.bounds.width
            if width > 800 { splitView.setPosition(250, ofDividerAt: 0); splitView.setPosition(510, ofDividerAt: 1) }
        }
    }
}

struct WorkspaceRevision: Equatable {
    struct Note: Equatable {
        var id: String
        var title: String
        var folder: String
        var preview: String
        var importedAt: Date
    }
    var selected: String?
    var notes: [Note]
}
