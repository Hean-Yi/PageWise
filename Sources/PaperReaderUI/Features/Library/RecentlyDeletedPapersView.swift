import PaperReaderKit
import SwiftUI

struct TrashPaperButton: View {
    let model: ReaderModel
    let paperID: UUID

    var body: some View {
        Button("移到最近删除", systemImage: "trash", role: .destructive) {
            Task { await model.trashPaper(paperID) }
        }
    }
}

struct RecentlyDeletedPapersView: View {
    let model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let papers = model.state.trashedPapers
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("最近删除").font(ReaderTheme.editorial(32, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 24)
                if papers.isEmpty {
                    ContentUnavailableView("没有已删除的论文", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(papers) { entry in
                    HStack(spacing: 14) {
                        BookCoverView(paper: entry.paper).frame(width: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.paper.title).font(ReaderTheme.editorial(18, weight: .medium)).lineLimit(3)
                            Text(entry.deletedAt, format: .dateTime.year().month().day())
                                .font(.caption).foregroundStyle(ReaderTheme.muted)
                        }
                        Spacer(minLength: 4)
                        Button {
                            Task { await model.restorePaper(entry.id) }
                        } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward").fixedSize()
                        }
                        .buttonStyle(.borderless).accessibilityLabel("恢复论文：\(entry.paper.title)")
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .animation(ReaderMotion.disclosure(reduceMotion), value: papers.count)
            .padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
    }
}
