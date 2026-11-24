import PaperReaderKit
import SwiftUI

/// A stable, typographic cover; no network image or published PDF page is modified.
struct BookCoverView: View {
    let paper: Paper
    var progress: ReadingProgress? = nil

    var body: some View {
        let palette = CoverPalette.forDigest(paper.digest)
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
        .animation(ReaderMotion.feedback(reduceMotion), value: progress)
        .allowsHitTesting(false)
    }
}

private struct CoverPalette {
    let paper: Color
    let ink: Color

    private static let palettes: [Self] = {
        let darkInk = Color(red: 0.19, green: 0.20, blue: 0.17)
        let lightInk = Color(red: 0.99, green: 0.96, blue: 0.90)
        return [
            Self(paper: Color(red: 0.80, green: 0.81, blue: 0.71), ink: darkInk),
            Self(paper: Color(red: 0.28, green: 0.34, blue: 0.31), ink: lightInk),
            Self(paper: Color(red: 0.92, green: 0.84, blue: 0.73), ink: darkInk),
            Self(paper: Color(red: 0.61, green: 0.34, blue: 0.26), ink: lightInk),
            Self(paper: Color(red: 0.78, green: 0.82, blue: 0.83), ink: darkInk),
        ]
    }()

    static func forDigest(_ digest: String) -> Self {
        let value = digest.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palettes[Int(value % UInt64(palettes.count))]
    }
}

struct BookshelfItem: View {
    @Environment(\.requestPaperDeletion) private var requestPaperDeletion
    @Bindable var model: ReaderModel
    let paper: Paper
    let recordFrame: (CGRect?) -> Void
    var searchLocated = false
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
    private var showsActions: Bool {
        #if os(iOS)
            true
        #else
            highlighted
        #endif
    }

    private func placedCover(_ progress: ReadingProgress) -> some View {
        BookCoverView(paper: paper, progress: progress)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ReaderTheme.accent, lineWidth: 2)
                    .padding(-4)
                    .opacity(searchLocated ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(ReaderMotion.feedback(reduceMotion), value: searchLocated)
            }
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(ShelfCoverFlight.coordinateSpace))
            } action: { frame in
                recordFrame(frame)
            }
            .shadow(
                color: .black.opacity(highlighted ? 0.16 : 0.09), radius: highlighted ? 10 : 4, y: highlighted ? 8 : 3
            )
    }

    var body: some View {
        let progress = self.progress
        VStack(alignment: .leading, spacing: 15) {
            placedCover(progress)
                .opacity(previewed ? 0 : 1)
                .animation(nil, value: previewed)
                .offset(y: highlighted && !reduceMotion ? -6 : 0)
                .opacity(lifted ? 0.28 : 1)
                .offset(arrangementOffset)
                .contentShape(Rectangle())
                #if os(macOS)
                    .overlay {
                        NativePaperDrag(
                            paper: paper, progress: progress, reduceMotion: reduceMotion,
                            begin: beginDrag, end: endDrag, accepts: acceptsDrop, hover: hoverDrop,
                            receive: receiveDrop,
                            focus: { focus = .cover }, open: { model.select(paper.id) })
                    }
                #else
                    .overlay {
                        TouchPaperDrag(
                            paper: paper, progress: progress, open: { model.select(paper.id) },
                            begin: beginDrag, end: endDrag, accepts: acceptsDrop, hover: hoverDrop, receive: receiveDrop
                        )
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
                .accessibilityAction(named: "删除论文") {
                    requestPaperDeletion?(PaperDeletionRequest(paper, model: model))
                }
                .help("\(paper.title) · \(progress.label) · 按住空格预览")
            HStack(spacing: 7) {
                Button {
                    showPreview(.pinned(paper.id))
                } label: {
                    Image(systemName: "eye").readerSymbolInk().readerIconTarget(macOS: 30)
                }
                .readerIconButtonStyle(.plain).focused($focus, equals: .preview)
                .foregroundStyle(ReaderTheme.muted).help("预览论文（按住空格）")
                .accessibilityLabel("预览论文：\(paper.title)")
                Spacer(minLength: 0)
                Button {
                    model.toggleFavorite(paper.id)
                } label: {
                    ReaderIcon(.favorite, filled: workspace.isFavorite)
                        .foregroundStyle(workspace.isFavorite ? ReaderTheme.accent : ReaderTheme.muted)
                        .readerIconTarget(macOS: 30)
                }.readerIconButtonStyle(.plain).focused($focus, equals: .favorite)
                    .help(workspace.isFavorite ? "取消收藏" : "收藏")
                    .accessibilityLabel("\(workspace.isFavorite ? "取消收藏" : "收藏") \(paper.title)")
                ReaderPopupMenu(paper.title + "的选项", items: actions) {
                    Image(systemName: "ellipsis").readerSymbolInk().font(.system(size: 16, weight: .semibold))
                        .readerIconTarget(macOS: 30)
                }.fixedSize()
                    .foregroundStyle(ReaderTheme.muted).focused($focus, equals: .menu)
                    .help("论文选项")
            }.frame(minHeight: 30).opacity(showsActions && !lifted ? 1 : 0)
                .offset(arrangementOffset)
        }
        .contentShape(Rectangle())
        .onHover {
            hovered = $0
            hoverCover($0)
        }
        .onDisappear {
            hoverCover(false)
            recordFrame(nil)
        }
        .animation(ReaderMotion.feedback(reduceMotion), value: highlighted)
        .readerContextMenu(paper.title + "的选项", items: actions)
    }

    private var actions: [ReaderMenuItem] {
        let status = progress.readingStatus
        let statuses = PaperReadingStatus.allCases.map { value in
            ReaderMenuItem.action(value.title, selected: value == status) {
                model.setReadingStatus(value, for: paper.id)
            }
        }
        return [
            .action("预览论文", icon: .source) { showPreview(.pinned(paper.id)) },
            .action("打开论文", icon: .paper) { model.select(paper.id) },
            .action(workspace.isFavorite ? "取消收藏" : "收藏", icon: .favorite) { model.toggleFavorite(paper.id) },
            .divider,
            .submenu("移动到书架", items: shelfDestinations),
            .action("向前移动", enabled: moveEarlier != nil) { moveEarlier?() },
            .action("向后移动", enabled: moveLater != nil) { moveLater?() },
            .section("阅读状态"),
        ] + statuses + [
            .divider,
            .action("删除论文…", icon: .delete, enabled: requestPaperDeletion != nil, destructive: true) {
                requestPaperDeletion?(PaperDeletionRequest(paper, model: model))
            },
        ]
    }

    private var shelfDestinations: [ReaderMenuItem] {
        let current = model.state.shelfID(for: paper.id)
        let unclassified = ReaderMenuItem.action("未分类", selected: current == nil) {
            Task { await model.movePaper(paper.id, to: nil) }
        }
        return [unclassified]
            + model.state.shelves.map { shelf in
                .action(shelf.name, selected: current == shelf.id) {
                    Task { await model.movePaper(paper.id, to: shelf.id) }
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
                            ReaderIcon(.add, size: 31)
                                .offset(y: revealed ? -25 : 0)
                            Text("拖拽 PDF 至此\n或点击在线查找")
                                .font(.system(size: 12)).lineSpacing(7).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .opacity(revealed ? 1 : 0)
                                .offset(y: revealed ? 24 : 32)
                        }.foregroundStyle(revealed ? ReaderTheme.accent : ReaderTheme.muted)
                    }.aspectRatio(0.70, contentMode: .fit)
                    .contentShape(Rectangle())
            }.readerIconButtonStyle(.plain).focused($focused).onHover { hovered = $0 }
                .animation(ReaderMotion.disclosure(reduceMotion), value: revealed)
                .help("拖拽 PDF 至此，或点击在线查找").accessibilityLabel("在线查找论文")
                .accessibilityHint("也可以拖拽 PDF 至此添加")
            Color.clear.frame(height: ReaderTheme.iconTarget(30)).accessibilityHidden(true)
        }
    }
}
