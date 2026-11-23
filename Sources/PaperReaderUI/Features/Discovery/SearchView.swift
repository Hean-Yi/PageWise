import PaperReaderKit
import SwiftUI

struct SearchView: View {
    @Bindable var search: OnlinePaperSearch
    let targetName: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("在线查找").font(.system(size: 20, weight: .medium, design: .serif))
                Text("arXiv").font(.system(size: 11, design: .monospaced)).foregroundStyle(ReaderTheme.muted)
                Spacer()
                Button {
                    search.close()
                } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("关闭在线查找").disabled(search.closing)
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.accent)
                TextField("输入论文标题", text: $search.query).textFieldStyle(.plain)
                    .focused($searchFocused).onSubmit { search.search() }.autocorrectionDisabled()
                    .disabled(search.importingID != nil)
                Button("查找") { search.search() }.buttonStyle(.borderedProminent)
                    .disabled(!search.canSearch)
            }.padding(14).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("导入到：\(targetName)").font(.caption).foregroundStyle(ReaderTheme.muted)
                Spacer()
                if search.isSearching {
                    ProgressView().controlSize(.small)
                    Button("取消查询") { search.cancelSearch() }.buttonStyle(.plain)
                }
                if search.closing { Text("正在停止导入…").font(.caption) }
            }
            if let notice = search.contextNotice {
                Text(notice).font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            if let error = search.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(ReaderTheme.accent)
                    HStack(spacing: 14) {
                        Button("重试") { search.search() }.buttonStyle(.plain)
                        if let url = search.webSearchURL {
                            Link(destination: url) { Label("在 arXiv 网页查找", systemImage: "arrow.up.right.square") }
                        }
                    }
                }
            } else if search.searched && search.results.isEmpty && !search.isSearching {
                Text("未找到论文，试试更短的标题").font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            ForEach(search.results) { item in candidateCard(item) }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line))
        .task(id: search.targetShelfID) {
            // Focus after the insertion transition has installed the native text field.
            do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
            searchFocused = true
        }
    }

    private func candidateCard(_ item: PaperCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(item.authors).font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2)
            HStack {
                Text(item.year).font(.caption).foregroundStyle(ReaderTheme.muted)
                if item.indexedByDataCite { Text("DataCite 索引").font(.caption).foregroundStyle(ReaderTheme.muted) }
                Link("arXiv 来源", destination: URL(string: item.id) ?? item.pdfURL).font(.caption)
                Spacer()
                if search.imported[item.id] != nil {
                    Label("已入库", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(
                        ReaderTheme.accent)
                } else if search.importingID == item.id {
                    ProgressView().controlSize(.small)
                    Button("停止导入") { search.cancelImport() }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(search.importErrors[item.id] == nil ? "导入论文" : "重试导入") { search.confirmImport(item) }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(search.importingID != nil)
                }
            }
            if search.importingID == item.id {
                ProgressView {
                    Text(search.importProgress).font(.caption)
                }.progressViewStyle(.linear)
            }
            if let error = search.importErrors[item.id] {
                Text(error).font(.caption).foregroundStyle(ReaderTheme.accent)
            }
        }.padding(16).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
