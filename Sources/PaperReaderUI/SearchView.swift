import PaperReaderKit
import SwiftUI

struct SearchView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PaperCandidate] = []
    @State private var busy = false
    @State private var searched = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("输入完整或近似标题。明确匹配会直接下载；其他结果请确认作者与年份。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("例如：Attention Is All You Need", text: $query).textFieldStyle(.roundedBorder).onSubmit {
                        search()
                    }
                    Button("查找", action: search).disabled(busy || query.isEmpty)
                }
                if busy { ProgressView("正在访问 arXiv…").frame(maxWidth: .infinity) }
                if searched && results.isEmpty && !busy {
                    ContentUnavailableView(
                        "没有找到匹配论文", systemImage: "doc.text.magnifyingglass",
                        description: Text("当前支持 arXiv。可缩短标题重试，或直接导入本地 PDF。"))
                }
                List(results) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        Text("\(item.year) · \(item.authors)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Link("查看来源", destination: URL(string: item.id) ?? item.pdfURL)
                            Spacer()
                            Button("确认并下载") {
                                busy = true
                                Task {
                                    await model.download(item)
                                    busy = false
                                    dismiss()
                                }
                            }.disabled(busy)
                        }.font(.callout)
                    }.padding(.vertical, 8)
                }.listStyle(.plain)
            }.padding(20)
                .navigationTitle("查找论文")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.frame(minWidth: 480, idealWidth: 650, minHeight: 480)
    }
    private func search() {
        guard !busy, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task {
            results = await model.search(query)
            searched = true
            let exact = results.filter { ArxivClient.normalized($0.title) == ArxivClient.normalized(query) }
            if exact.count == 1 {
                await model.download(exact[0])
                dismiss()
            }
            busy = false
        }
    }
}
