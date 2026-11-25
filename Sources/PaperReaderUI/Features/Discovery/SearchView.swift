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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("在线查找").font(ReaderTheme.editorial(23, weight: .medium))
                    .foregroundStyle(ReaderTheme.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                ReaderPopupMenu(
                    "检索来源，" + scopeTitle(search.scope),
                    items: PaperSearchScope.allCases.map { scope in
                        .action(scopeTitle(scope), selected: scope == search.scope) { search.selectScope(scope) }
                    }
                ) {
                    ReaderMenuValueLabel(scopeTitle(search.scope)).font(.caption)
                }
                .fixedSize().disabled(search.importingID != nil)
                Button {
                    search.close()
                } label: {
                    ReaderIcon(.close, size: 15).readerIconTarget(macOS: 34)
                        .background(ReaderTheme.elevated, in: Circle())
                }
                .readerPlainButton(cornerRadius: 17).foregroundStyle(ReaderTheme.ink)
                .keyboardShortcut(.cancelAction).accessibilityLabel("关闭在线查找")
                .accessibilityIdentifier("online-search-close").help("关闭在线查找")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted).accessibilityHidden(true)
                TextField("题名、关键词或 DOI", text: $search.query)
                    .textFieldStyle(.plain).focused($searchFocused).submitLabel(.search)
                    .onSubmit { search.search() }.autocorrectionDisabled()
                    .disabled(search.importingID != nil)
                Button("查找") { search.search() }
                    .font(.callout.weight(.semibold)).foregroundStyle(
                        search.canSearch ? ReaderTheme.accent : ReaderTheme.muted
                    )
                    .readerPlainButton().disabled(!search.canSearch)
            }
            .padding(.horizontal, 12).frame(minHeight: 42)
            .readerGlassSurface(in: RoundedRectangle(cornerRadius: 9), bordered: true)
            .quickStartTarget(.discovery)
            HStack(spacing: 6) {
                ReaderIcon(.library, size: 13)
                Text("导入到 \(targetName)").lineLimit(1).accessibilityIdentifier("online-import-destination")
                Spacer(minLength: 4)
                if search.isSearching {
                    ProgressView().controlSize(.small)
                    Button("取消查询") { search.cancelSearch() }.readerPlainButton()
                }
            }
            .font(.caption).foregroundStyle(ReaderTheme.muted)
            if let error = search.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(ReaderTheme.accent)
                    HStack(spacing: 14) {
                        Button("重试") { search.search() }.readerPlainButton()
                        if let url = search.webSearchURL {
                            Link(destination: url) {
                                Label("在 arXiv 网页查找", systemImage: "arrow.up.right.square")
                                    .labelStyle(ReaderSymbolLabelStyle())
                            }.readerIconButtonStyle(.plain)
                        }
                    }
                }
            } else if let notice = search.sourceNotice {
                Text(notice).font(.caption).foregroundStyle(ReaderTheme.muted)
            } else if search.searched && search.results.isEmpty && !search.isSearching {
                Text("未找到论文，试试更短的标题").font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            if !search.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(search.results) { item in
                        Divider().accessibilityHidden(true)
                        OnlineCandidateCard(search: search, candidate: item) { version in
                            choosingPDF = search.choosePDF(for: version)
                        }
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(ReaderTheme.surface)
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line) }
                .allowsHitTesting(false)
        }
        .publisherPDFImporter(
            isPresented: $choosingPDF, importFile: search.importSelectedPDF, onFailure: search.fileSelectionFailed,
            onCancellation: search.cancelFileSelection
        )
        .task { searchFocused = true }
    }
}

extension PaperCandidate {
    var searchResultTitle: String {
        guard title.contains("$") else { return title }
        // Show a literal single-letter math symbol directly. Keep TeX expressions and currency intact.
        return title.replacingOccurrences(
            of: #"(?<![\\$])\$(\p{L}\p{M}*)\$(?![\p{Nd}$])"#, with: "$1", options: .regularExpression)
    }
}

private struct OnlineCandidateCard: View {
    let search: OnlinePaperSearch
    let candidate: PaperCandidate
    let choosePDF: (PaperCandidate) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedVersionID: String?
    @State private var hovered = false

    var body: some View {
        let versions = [candidate] + candidate.alternateVersions
        let item =
            versions.first { $0.id == selectedVersionID } ?? versions.first { $0.id == search.selectedPublicationID }
            ?? candidate
        let imported = search.importedPaperID(for: item) != nil
        VStack(alignment: .leading, spacing: 6) {
            versionInfo(item, versions: versions)
            let title = SearchMatchText(item.searchResultTitle, query: search.resultQuery)
                .font(ReaderTheme.editorial(19, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let url = item.landingURL {
                Link(destination: url) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        title
                        Image(systemName: "arrow.up.right").font(.caption2).readerSymbolInk()
                            .foregroundStyle(ReaderTheme.muted).accessibilityHidden(true)
                    }
                    .multilineTextAlignment(.leading).contentShape(Rectangle())
                }
                .readerIconButtonStyle(.plain).foregroundStyle(hovered ? ReaderTheme.accent : ReaderTheme.ink)
                .help(item.landingPageLabel)
            } else {
                title.foregroundStyle(ReaderTheme.ink)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    authors(item).frame(minWidth: 100, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
                    actions(for: item, imported: imported).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    authors(item)
                    actions(for: item, imported: imported)
                }
            }
            if search.importingID == item.id {
                ProgressView { Text(search.importProgress).font(.caption) }.progressViewStyle(.linear)
            }
            if let error = search.importErrors[item.id] {
                Text(error).font(.caption).foregroundStyle(ReaderTheme.accent)
                if item.canAttemptDownload, !imported { selectPDFButton(item) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.elevated.opacity(hovered ? 0.64 : 0), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .animation(ReaderMotion.feedback(reduceMotion), value: hovered)
    }

    @ViewBuilder private func authors(_ item: PaperCandidate) -> some View {
        if !item.authors.isEmpty {
            SearchMatchText(item.authors, query: search.resultQuery)
                .font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2).help(item.authors)
        }
    }

    private func versionInfo(_ item: PaperCandidate, versions: [PaperCandidate]) -> some View {
        HStack(spacing: 7) {
            if versions.count > 1 {
                ReaderPopupMenu(
                    "论文版本，" + versionLabel(for: item),
                    items: versions.map { version in
                        .action(versionLabel(for: version), selected: version.id == item.id) {
                            selectedVersionID = version.id
                        }
                    }
                ) {
                    ReaderMenuValueLabel(versionLabel(for: item))
                }.fixedSize().disabled(search.importingID != nil)
            } else {
                Text(item.source.label)
            }
            if !item.year.isEmpty {
                Text("·").accessibilityHidden(true)
                Text(item.year)
            }
        }.font(.caption).foregroundStyle(ReaderTheme.muted)
    }

    @ViewBuilder private func actions(for item: PaperCandidate, imported: Bool) -> some View {
        if imported {
            Button {
                search.openImported(item)
            } label: {
                Label("在书库打开", readerIcon: .library)
            }
            .readerIconButtonStyle(DiscoveryAction())
        } else if search.importingID == item.id {
            Button("停止导入") { search.cancelImport() }.readerIconButtonStyle(DiscoveryAction())
        } else if item.canAttemptDownload {
            Button {
                search.confirmImport(item)
            } label: {
                Label(search.importErrors[item.id] == nil ? "下载并导入" : "重试导入", systemImage: "arrow.down.to.line")
                    .labelStyle(ReaderSymbolLabelStyle())
            }
            .readerIconButtonStyle(DiscoveryAction()).disabled(search.importingID != nil)
        } else {
            selectPDFButton(item)
        }
    }

    private func selectPDFButton(_ item: PaperCandidate) -> some View {
        Button {
            choosePDF(item)
        } label: {
            PublisherPDFImportLabel()
        }
        .readerIconButtonStyle(DiscoveryAction()).disabled(search.importingID != nil)
    }

    private func versionLabel(for item: PaperCandidate) -> String {
        if item.source == .arxiv, let id = ArxivClient.versionedIdentifier(item.id), let v = id.lastIndex(of: "v") {
            return "arXiv " + id[v...]
        }
        return item.source.label
    }
}

private struct DiscoveryAction: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.weight(.semibold))
            .padding(.horizontal, 10).frame(minHeight: ReaderTheme.iconTarget(28))
            .foregroundStyle(enabled ? ReaderTheme.accent : ReaderTheme.muted)
            .background(ReaderTheme.accent.opacity(configuration.isPressed ? 0.16 : 0.07), in: Capsule())
            .contentShape(Capsule())
    }
}
