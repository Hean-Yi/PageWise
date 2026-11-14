import PaperReaderKit
import SwiftUI

/// A stable, typographic cover; no network image or published PDF page is modified.
struct BookCoverView: View {
    let paper: Paper

    private var palette: CoverPalette { CoverPalette.forDigest(paper.digest) }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 220
            ZStack(alignment: .leading) {
                palette.paper
                LinearGradient(
                    colors: [.black.opacity(0.15), .white.opacity(0.3), .clear, .black.opacity(0.07), .clear],
                    startPoint: .leading, endPoint: .trailing
                ).frame(width: 16 * scale)
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(palette.ink.opacity(0.55)).frame(width: 28 * scale, height: 2 * scale)
                    Spacer(minLength: 16 * scale)
                    Text(paper.title)
                        .font(.system(size: 27 * scale, weight: .medium, design: .serif))
                        .tracking(-0.4 * scale).lineSpacing(4 * scale)
                        .lineLimit(8).minimumScaleFactor(0.62)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 22 * scale)
                    HStack {
                        Text("PAPER").tracking(2.4 * scale)
                        Spacer()
                        Image(systemName: "text.book.closed")
                    }.font(.system(size: 9 * scale, weight: .medium))
                        .foregroundStyle(palette.ink.opacity(0.6))
                }
                .foregroundStyle(palette.ink)
                .padding(.leading, 28 * scale).padding(.trailing, 22 * scale)
                .padding(.vertical, 26 * scale)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 5, topTrailingRadius: 5)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.09), lineWidth: 0.5)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(.white.opacity(0.35)).frame(width: 1).padding(.vertical, 3).padding(.trailing, 2)
            }
        }.aspectRatio(0.70, contentMode: .fit).accessibilityHidden(true)
    }
}

private struct CoverPalette {
    let paper: Color
    let ink: Color

    static func forDigest(_ digest: String) -> CoverPalette {
        let value = digest.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let darkInk = Color(red: 0.20, green: 0.23, blue: 0.21)
        let lightInk = Color(red: 0.96, green: 0.94, blue: 0.86)
        let palettes = [
            CoverPalette(paper: Color(red: 0.86, green: 0.86, blue: 0.78), ink: darkInk),
            CoverPalette(paper: Color(red: 0.31, green: 0.39, blue: 0.36), ink: lightInk),
            CoverPalette(paper: Color(red: 0.91, green: 0.83, blue: 0.72), ink: darkInk),
            CoverPalette(paper: Color(red: 0.49, green: 0.29, blue: 0.23), ink: lightInk),
            CoverPalette(paper: Color(red: 0.81, green: 0.85, blue: 0.87), ink: darkInk),
        ]
        return palettes[Int(value % UInt64(palettes.count))]
    }
}

struct BookshelfItem: View {
    @Bindable var model: ReaderModel
    let paper: Paper
    @State private var hovered = false
    @FocusState private var focus: Control?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Control: Hashable { case cover, favorite, menu }
    private var workspace: PaperWorkspace { model.workspace(for: paper.id) }
    private var progress: ReadingProgress { .resolve(paper: paper, workspace: workspace) }
    private var highlighted: Bool { hovered || focus != nil }
    private var showsActions: Bool { highlighted }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Button {
                model.select(paper.id)
            } label: {
                BookCoverView(paper: paper)
                    .shadow(
                        color: .black.opacity(highlighted ? 0.22 : 0.14), radius: highlighted ? 16 : 10, x: 0,
                        y: highlighted ? 14 : 9
                    )
                    .offset(y: highlighted && !reduceMotion ? -6 : 0)
                    .contentShape(Rectangle())
                    .draggable(PaperShelfDrag(paperID: paper.id))
            }.buttonStyle(.plain).focused($focus, equals: .cover)
                .accessibilityLabel("打开论文：\(paper.title)")
                .accessibilityValue(progress.label).help(paper.title)
            HStack(spacing: 7) {
                Text(progress.label).font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                Spacer(minLength: 0)
                Button {
                    model.toggleFavorite(paper.id)
                } label: {
                    Image(systemName: workspace.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(workspace.isFavorite ? ReaderTheme.accent : ReaderTheme.muted)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).focused($focus, equals: .favorite)

                    .help(workspace.isFavorite ? "取消收藏" : "收藏")
                    .accessibilityLabel("\(workspace.isFavorite ? "取消收藏" : "收藏") \(paper.title)")
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                        .frame(width: 24, height: 30).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(ReaderTheme.muted).focused($focus, equals: .menu)
                    .help("论文选项").accessibilityLabel("\(paper.title)的选项")
            }.frame(height: 30).opacity(showsActions ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: highlighted)
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("打开论文") { model.select(paper.id) }
        Button(workspace.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(paper.id) }
        Menu("移动到书架") {
            Button("未分类") { Task { await model.movePaper(paper.id, to: nil) } }
            ForEach(model.state.shelves) { shelf in
                Button {
                    Task { await model.movePaper(paper.id, to: shelf.id) }
                } label: {
                    if model.state.shelfID(for: paper.id) == shelf.id {
                        Label(shelf.name, systemImage: "checkmark")
                    } else {
                        Text(shelf.name)
                    }
                }
            }
        }
        Divider()
        ForEach(PaperReadingStatus.allCases, id: \.self) { value in
            Button {
                model.setReadingStatus(value, for: paper.id)
            } label: {
                if progress.readingStatus == value {
                    Label("标记为\(value.title)", systemImage: "checkmark")
                } else {
                    Text("标记为\(value.title)")
                }
            }
        }
    }
}

struct AddPaperCover: View {
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revealed: Bool { hovered || focused }

    var body: some View {
        VStack(spacing: 15) {
            Button(action: action) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(ReaderTheme.ink.opacity(revealed ? 0.035 : 0.012))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(
                            revealed ? ReaderTheme.accent.opacity(0.65) : ReaderTheme.ink.opacity(0.17),
                            style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                    }
                    .overlay {
                        ZStack {
                            Image(systemName: "plus").font(.system(size: 30, weight: .ultraLight))
                                .offset(y: revealed ? -25 : 0)
                            Text("拖拽 PDF 至此\n或点击在线查找")
                                .font(.system(size: 12)).lineSpacing(7).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .opacity(revealed ? 1 : 0)
                                .offset(y: revealed ? 24 : 32)
                        }.foregroundStyle(revealed ? ReaderTheme.accent : ReaderTheme.muted)
                    }.aspectRatio(0.70, contentMode: .fit)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focused).onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: revealed)
                .help("拖拽 PDF 至此，或点击在线查找").accessibilityLabel("在线查找论文")
                .accessibilityHint("也可以拖拽 PDF 至此添加")
            Color.clear.frame(height: 30).accessibilityHidden(true)
        }
    }
}
