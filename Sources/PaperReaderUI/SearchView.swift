import PaperReaderKit
import SwiftUI

struct SearchView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PaperCandidate] = []
    @State private var busy = false
    @State private var downloading = false
    @State private var searched = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 10) {
                    Text("查找论文").font(.system(size: 28, weight: .regular, design: .serif))
                    Text("arXiv").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ReaderTheme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(ReaderTheme.surface, in: Capsule())
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ReaderTheme.muted)
                            .frame(width: 30, height: 30)
                            .background(ReaderTheme.surface, in: Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("关闭查找论文")
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(ReaderTheme.accent)
                    TextField("输入论文标题", text: $query).textFieldStyle(.plain).font(.body)
                        .focused($searchFocused).onSubmit { search() }.disabled(busy)
                        .autocorrectionDisabled()
                    Button("查找", action: search)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(14)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(searchFocused ? ReaderTheme.accent.opacity(0.55) : ReaderTheme.line))
            }.padding(24)
            Divider().overlay(ReaderTheme.line)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(downloading ? "下载中…" : "查找中…").font(.subheadline)
                        }
                        .foregroundStyle(ReaderTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    if results.isEmpty && !busy {
                        emptyState
                    } else {
                        if !results.isEmpty {
                            Text("\(results.count) 个结果").font(.caption).foregroundStyle(ReaderTheme.muted)
                        }
                        ForEach(results) { item in
                            candidateCard(item)
                        }
                    }
                }.padding(24)
            }
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
        #if os(macOS)
            .frame(width: 640, height: 660)
        #else
            .presentationSizing(.form)
        #endif
        .onAppear { searchFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .ultraLight)).foregroundStyle(ReaderTheme.accent.opacity(0.6))
            Text(searched ? "未找到论文" : "按标题查找").font(.headline)
            if searched {
                Text("试试更短的标题").font(.subheadline).foregroundStyle(ReaderTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func candidateCard(_ item: PaperCandidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.system(size: 16, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(item.authors).font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2)
            HStack(spacing: 12) {
                Text(String(item.year)).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ReaderTheme.muted)
                Link(destination: URL(string: item.id) ?? item.pdfURL) {
                    Image(systemName: "arrow.up.right").font(.caption)
                }
                .foregroundStyle(ReaderTheme.muted).help("查看 arXiv 来源")
                .accessibilityLabel("查看\(item.title)的来源")
                Spacer()
                Button {
                    busy = true
                    downloading = true
                    Task {
                        await model.download(item)
                        busy = false
                        downloading = false
                        dismiss()
                    }
                } label: {
                    Label("下载", systemImage: "arrow.down")
                }.buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !term.isEmpty else { return }
        busy = true
        downloading = false
        Task {
            results = await model.search(term)
            searched = true
            let exact = results.filter { ArxivClient.normalized($0.title) == ArxivClient.normalized(term) }
            if exact.count == 1 {
                downloading = true
                await model.download(exact[0])
                dismiss()
            }
            busy = false
            downloading = false
        }
    }
}
