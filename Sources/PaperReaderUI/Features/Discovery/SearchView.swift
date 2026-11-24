import PaperReaderKit
import SwiftUI

struct SearchView: View {
    @Bindable var search: OnlinePaperSearch
    let targetName: String
    @FocusState private var searchFocused: Bool
    @State private var choosingPDF = false

    private func scopeTitle(_ scope: PaperSearchScope) -> String {
        switch scope {
        case .all: "全部来源"
        case .arxiv: "arXiv"
        case .crossref: "Crossref"
        case .dblp: "DBLP"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("在线查找").font(.system(size: 20, weight: .medium, design: .serif))
                Spacer()
                Menu {
                    ForEach(PaperSearchScope.allCases, id: \.self) { scope in
                        Button {
                            search.selectScope(scope)
                        } label: {
                            if scope == search.scope {
                                Label(scopeTitle(scope), systemImage: "checkmark")
                            } else {
                                Text(scopeTitle(scope))
                            }
                        }
                    }
                } label: {
                    Text(scopeTitle(search.scope))
                }
                .accessibilityLabel("检索来源，" + scopeTitle(search.scope)).fixedSize().controlSize(.small)
                .disabled(search.importingID != nil)
                Button {
                    search.close()
                } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("关闭在线查找").disabled(search.closing)
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.accent)
                TextField("题名、关键词或 DOI", text: $search.query).textFieldStyle(.plain)
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
            } else if let notice = search.sourceNotice {
                Text(notice).font(.caption).foregroundStyle(ReaderTheme.muted)
            } else if search.searched && search.results.isEmpty && !search.isSearching {
                Text("未找到论文，试试更短的标题").font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            ForEach(search.results) { item in
                OnlineCandidateCard(search: search, candidate: item) { version in
                    choosingPDF = search.choosePDF(for: version)
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line))
        .publisherPDFImporter(
            isPresented: $choosingPDF, importFile: search.importSelectedPDF, onFailure: search.fileSelectionFailed,
            onCancellation: search.cancelFileSelection
        )
        .task(id: search.targetShelfID) {
            // Focus after the insertion transition has installed the native text field.
            do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
            searchFocused = true
        }
    }

}

private struct OnlineCandidateCard: View {
    let search: OnlinePaperSearch
    let candidate: PaperCandidate
    let choosePDF: (PaperCandidate) -> Void
    @State private var selectedVersionID: String?

    var body: some View {
        let versions = [candidate] + candidate.alternateVersions
        let item =
            versions.first { $0.id == selectedVersionID } ?? versions.first { $0.id == search.selectedPublicationID }
            ?? candidate
        VStack(alignment: .leading, spacing: 10) {
            SearchMatchText(item.title, query: search.resultQuery)
                .font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if !item.authors.isEmpty {
                SearchMatchText(item.authors, query: search.resultQuery)
                    .font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    versionInfo(item, versions: versions)
                    Spacer(minLength: 12)
                    actions(for: item)
                }
                VStack(alignment: .leading, spacing: 8) {
                    versionInfo(item, versions: versions)
                    actions(for: item)
                }
            }
            if search.importingID == item.id {
                ProgressView {
                    Text(search.importProgress).font(.caption)
                }.progressViewStyle(.linear)
            }
            if let error = search.importErrors[item.id] {
                Text(error).font(.caption).foregroundStyle(ReaderTheme.accent)
                if item.canAttemptDownload, search.importedPaperID(for: item) == nil {
                    selectPDFButton(item).controlSize(.small)
                }
            }
        }.padding(16).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func versionInfo(_ item: PaperCandidate, versions: [PaperCandidate]) -> some View {
        HStack {
            if !item.year.isEmpty { Text(item.year).font(.caption).foregroundStyle(ReaderTheme.muted) }
            if versions.count > 1 {
                Picker("论文版本", selection: Binding(get: { item.id }, set: { selectedVersionID = $0 })) {
                    ForEach(versions) { version in
                        Text(versionLabel(for: version)).tag(version.id)
                    }
                }.pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    .disabled(search.importingID != nil)
            } else {
                Text(item.source.label).font(.caption).foregroundStyle(ReaderTheme.muted)
            }
        }
    }

    private func actions(for item: PaperCandidate) -> some View {
        HStack {
            if let url = item.landingURL {
                if item.canAttemptDownload && search.importErrors[item.id] == nil {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .accessibilityLabel(item.landingPageLabel).help(item.landingPageLabel)
                } else {
                    Link(destination: url) { Label(item.landingPageLabel, systemImage: "arrow.up.right.square") }
                        .buttonStyle(.bordered)
                }
            }
            if search.importedPaperID(for: item) != nil {
                Button {
                    search.openImported(item)
                } label: {
                    Label("在书库打开", systemImage: "checkmark.circle.fill")
                }.buttonStyle(.bordered)
            } else if search.importingID == item.id {
                ProgressView().controlSize(.small)
                Button("停止导入") { search.cancelImport() }.buttonStyle(.bordered)
            } else if item.canAttemptDownload {
                Button(search.importErrors[item.id] == nil ? "下载并导入" : "重试导入") { search.confirmImport(item) }
                    .buttonStyle(.borderedProminent).disabled(search.importingID != nil)
            } else {
                selectPDFButton(item)
            }
        }.controlSize(.small)
    }

    private func selectPDFButton(_ item: PaperCandidate) -> some View {
        Button {
            choosePDF(item)
        } label: {
            PublisherPDFImportLabel()
        }
        .buttonStyle(.bordered).disabled(search.importingID != nil)
    }

    private func versionLabel(for item: PaperCandidate) -> String {
        if item.source == .arxiv, let id = ArxivClient.versionedIdentifier(item.id), let v = id.lastIndex(of: "v") {
            return "arXiv " + id[v...]
        }
        return item.source.label
    }
}
