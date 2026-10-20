import SwiftUI

struct SourceBrowser: View {
    @ObservedObject var workspace: Workspace
    let importedIDs: Set<String>
    @State private var filter = SourceFilter()
    @State private var showingFilters = false
    private var visible: [SourceNote] { workspace.sources.filter { filter.matches($0, importedIDs: importedIDs) } }
    private var visibleIDs: Set<String> { Set(visible.map(\.id)) }
    private var hiddenSelection: Int { workspace.selected.subtracting(visibleIDs).count }
    private var groups: [String] { filter.isActive ? Array(Set(visible.map(\.folder))).sorted() : workspace.folders }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("备忘录来源", systemImage: "folder").font(.headline)
                Spacer()
                Menu {
                    Button("全选可见笔记") { workspace.selected.formUnion(visible.filter { !$0.locked }.map(\.id)) }.disabled(workspace.busy)
                    Button("清空勾选") { workspace.selected.removeAll() }.disabled(workspace.selected.isEmpty)
                    Divider()
                    Button("重置搜索与筛选") { filter = SourceFilter() }.disabled(!filter.isActive)
                } label: { Image(systemName: "ellipsis.circle") }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().help("来源操作")
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索来源", text: $filter.query).textFieldStyle(.plain).accessibilityIdentifier("sourceSearch")
                    if !filter.query.isEmpty { Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                }.padding(7).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                Button { showingFilters.toggle() } label: {
                    Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(filter.isActive ? Color.accentColor : Color.secondary)
                }.buttonStyle(.plain).font(.system(size: 18)).help("筛选来源").accessibilityIdentifier("sourceFilters")
                    .popover(isPresented: $showingFilters) { filters.padding(18).frame(width: 300) }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack {
                Text("\(visible.count) 篇").accessibilityIdentifier("sourceResultCount")
                Spacer()
                if !workspace.selected.isEmpty { Text("已选 \(workspace.selected.count)").foregroundStyle(Color.accentColor) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 9)
            Divider()
            if hiddenSelection > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("其中 \(hiddenSelection) 篇勾选被筛选隐藏")
                    Button("仅保留可见勾选") { workspace.selected.formIntersection(visibleIDs) }.buttonStyle(.link)
                }.font(.caption).foregroundStyle(.orange).padding(12)
            }
            if !workspace.loaded {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                    Text("连接备忘录").font(.headline)
                    Button("读取来源") { Task { await workspace.load() } }.disabled(workspace.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(filter.isActive ? "没有匹配的笔记" : "没有可读取的笔记", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.self) { folder in
                        Section {
                            ForEach(visible.filter { $0.folder == folder }) { note in noteRow(note) }
                        } header: {
                            Label(folder, systemImage: "folder")
                                .contextMenu {
                                    Button("选中此文件夹") { workspace.selected.formUnion(visible.filter { $0.folder == folder && !$0.locked }.map(\.id)) }
                                    Button("取消此文件夹勾选") { workspace.selected.subtract(visible.filter { $0.folder == folder }.map(\.id)) }
                                }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.background(Color(nsColor: .textBackgroundColor))
        .onChange(of: workspace.folders) { _, folders in
            if let selected = filter.folder, !folders.contains(selected) { filter.folder = nil }
        }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("筛选来源").font(.headline); Spacer(); Button("重置") { filter = SourceFilter() }.disabled(!filter.isActive) }
            Divider()
            Picker("文件夹", selection: $filter.folder) {
                Text("全部文件夹").tag(nil as String?)
                ForEach(workspace.folders, id: \.self) { Text($0).tag(Optional($0)) }
            }.accessibilityIdentifier("folderFilter")
            Picker("附件", selection: $filter.attachments) { ForEach(AttachmentFilter.allCases) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("attachmentFilter")
            Picker("导入", selection: $filter.imported) { ForEach(ImportFilter.allCases) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("importFilter")
            Picker("访问", selection: $filter.access) { ForEach(AccessFilter.allCases) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("accessFilter")
        }
    }
    private func noteRow(_ note: SourceNote) -> some View {
        Toggle(isOn: Binding(get: { workspace.selected.contains(note.id) }, set: {
            if $0 { workspace.selected.insert(note.id) } else { workspace.selected.remove(note.id) }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Label(note.title.isEmpty ? "无标题" : note.title, systemImage: note.locked ? "lock.fill" : "note.text").lineLimit(2)
                HStack(spacing: 8) {
                    if let count = note.attachmentCount { Text(count == 0 ? "无附件" : "\(count) 个附件") }
                    else { Text("附件情况未知") }
                    if importedIDs.contains(note.id) { Label("已导入", systemImage: "checkmark.circle") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(note.locked || workspace.busy).help(note.locked ? "密码保护笔记暂不支持导入" : note.title)
    }
}
