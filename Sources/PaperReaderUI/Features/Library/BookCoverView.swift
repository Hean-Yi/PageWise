import PaperReaderKit
import SwiftUI

/// A stable, typographic cover; no network image or published PDF page is modified.
struct BookCoverView: View {
    let paper: Paper
    var progress: ReadingProgress? = nil

    private var palette: CoverPalette { CoverPalette.forDigest(paper.digest) }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 220
            ZStack(alignment: .leading) {
                palette.paper
                Rectangle().fill(palette.ink.opacity(0.12)).frame(width: 3 * scale)
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(palette.ink.opacity(0.65)).frame(width: 32 * scale, height: 1.5 * scale)
                        .padding(.bottom, 35 * scale)
                    Text(paper.title)
                        .font(ReaderTheme.editorial(28 * scale, weight: .medium))
                        .tracking(-0.6 * scale).lineSpacing(2 * scale)
                        .lineLimit(8).minimumScaleFactor(0.62)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 22 * scale)
                    if paper.pageCount > 0 {
                        Rectangle().fill(palette.ink.opacity(0.24)).frame(height: 0.7 * scale)
                        Text("\(paper.pageCount) 页").font(.system(size: 10 * scale, weight: .medium))
                            .foregroundStyle(palette.ink.opacity(0.8)).padding(.top, 9 * scale)
                    }
                }
                .foregroundStyle(palette.ink)
                .padding(.leading, 23 * scale).padding(.trailing, 20 * scale)
                .padding(.top, 28 * scale).padding(.bottom, 19 * scale)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 5, topTrailingRadius: 5)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.09), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if let progress {
                    CoverProgressRing(progress: progress, ink: palette.ink)
                        .frame(width: 26 * scale, height: 26 * scale)
                        .padding(16 * scale)
                }
            }
        }.aspectRatio(0.70, contentMode: .fit).accessibilityHidden(true)
    }
}

private struct CoverProgressRing: View {
    let progress: ReadingProgress
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let lineWidth = geometry.size.width / 13
            ZStack {
                Circle().stroke(
                    ink.opacity(0.22),
                    style: StrokeStyle(lineWidth: lineWidth, dash: progress.fraction == nil ? [2, 3] : []))
                if let fraction = progress.fraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(ink.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if fraction == 1 {
                        Image(systemName: "checkmark")
                            .font(.system(size: geometry.size.width * 0.4, weight: .medium))
                            .foregroundStyle(ink.opacity(0.85))
                    }
                }
            }.padding(lineWidth / 2)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: progress)
        .allowsHitTesting(false)
    }
}

private struct CoverPalette {
    let paper: Color
    let ink: Color

    static func forDigest(_ digest: String) -> CoverPalette {
        let value = digest.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let darkInk = Color(red: 0.19, green: 0.20, blue: 0.17)
        let lightInk = Color(red: 0.99, green: 0.96, blue: 0.90)
        let palettes = [
            CoverPalette(paper: Color(red: 0.80, green: 0.81, blue: 0.71), ink: darkInk),
            CoverPalette(paper: Color(red: 0.28, green: 0.34, blue: 0.31), ink: lightInk),
            CoverPalette(paper: Color(red: 0.92, green: 0.84, blue: 0.73), ink: darkInk),
            CoverPalette(paper: Color(red: 0.61, green: 0.34, blue: 0.26), ink: lightInk),
            CoverPalette(paper: Color(red: 0.78, green: 0.82, blue: 0.83), ink: darkInk),
        ]
        return palettes[Int(value % UInt64(palettes.count))]
    }
}

struct BookshelfItem: View {
    @Bindable var model: ReaderModel
    let paper: Paper
    let covers: Namespace.ID
    let previewed: Bool
    let showPreview: (ShelfPreviewTarget) -> Void
    let releasePreview: () -> Bool
    let hoverCover: (Bool) -> Void
    var lifted = false
    var arrangementOffset = CGSize.zero
    var beginDrag: () -> Void = {}
    var endDrag: () -> Void = {}
    var acceptsDrop: (UUID) -> Bool = { _ in false }
    var hoverDrop: (UUID) -> Void = { _ in }
    var receiveDrop: (UUID) -> Bool = { _ in false }
    var moveEarlier: (() -> Void)?
    var moveLater: (() -> Void)?
    @State private var hovered = false
    @FocusState private var focus: Control?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Control: Hashable { case cover, preview, favorite, menu }
    private var workspace: PaperWorkspace { model.workspace(for: paper.id) }
    private var progress: ReadingProgress { .resolve(paper: paper, workspace: workspace) }
    private var highlighted: Bool { hovered || focus != nil }
    private var showsActions: Bool { highlighted }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ZStack {
                Color.clear.aspectRatio(0.70, contentMode: .fit).accessibilityHidden(true)
                if !previewed {
                    BookCoverView(paper: paper, progress: progress)
                        .matchedGeometryEffect(id: paper.id, in: covers)
                        .transition(.identity)
                        .shadow(
                            color: .black.opacity(highlighted ? 0.16 : 0.09), radius: highlighted ? 10 : 4, x: 0,
                            y: highlighted ? 8 : 3
                        )
                        .offset(y: highlighted && !reduceMotion ? -6 : 0)
                }
            }
            .opacity(lifted ? 0.28 : 1)
            .offset(arrangementOffset)
            .contentShape(Rectangle())
            #if os(macOS)
                .overlay {
                    NativePaperDrag(
                        paper: paper, progress: progress, reduceMotion: reduceMotion,
                        begin: beginDrag, end: endDrag, accepts: acceptsDrop, hover: hoverDrop, receive: receiveDrop,
                        focus: { focus = .cover }, open: { model.select(paper.id) })
                }
            #else
                .overlay {
                    TouchPaperDrag(
                        paper: paper, progress: progress, open: { model.select(paper.id) },
                        begin: beginDrag, end: endDrag, accepts: acceptsDrop, hover: hoverDrop, receive: receiveDrop)
                }
            #endif
            .focusable().focused($focus, equals: .cover)
            .onKeyPress(.return) {
                model.select(paper.id)
                return .handled
            }
            .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { key in
                guard key.modifiers.isEmpty else { return .ignored }
                if key.phase == .down { showPreview(.held(paper.id)) }
                if key.phase == .up { _ = releasePreview() }
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("打开论文：\(paper.title)")
            .accessibilityValue(progress.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.select(paper.id) }
            .accessibilityAction(named: "预览论文") { showPreview(.pinned(paper.id)) }
            .help("\(paper.title) · \(progress.label) · 按住空格预览")
            HStack(spacing: 7) {
                Button {
                    showPreview(.pinned(paper.id))
                } label: {
                    Image(systemName: "eye").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focused($focus, equals: .preview)
                .foregroundStyle(ReaderTheme.muted).help("预览论文（按住空格）")
                .accessibilityLabel("预览论文：\(paper.title)")
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
            }.frame(height: 30).opacity(showsActions && !lifted ? 1 : 0)
                .offset(arrangementOffset)
        }
        .contentShape(Rectangle())
        .onHover {
            hovered = $0
            hoverCover($0)
        }
        .onDisappear { hoverCover(false) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: highlighted)
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("预览论文") { showPreview(.pinned(paper.id)) }
        Button("打开论文") { model.select(paper.id) }
        Button(workspace.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(paper.id) }
        Button("向前移动") { moveEarlier?() }.disabled(moveEarlier == nil)
        Button("向后移动") { moveLater?() }.disabled(moveLater == nil)
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
