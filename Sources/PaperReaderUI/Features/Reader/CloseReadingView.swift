import PaperReaderKit
import SwiftUI

extension CloseReadingDimension {
    var swatch: Color {
        switch self {
        case .thesis: Color(red: 0.95, green: 0.81, blue: 0.39)
        case .concept: Color(red: 0.92, green: 0.55, blue: 0.52)
        case .evidence: Color(red: 0.54, green: 0.73, blue: 0.92)
        case .rebuttal: Color(red: 0.64, green: 0.79, blue: 0.48)
        case .method: Color(red: 0.73, green: 0.62, blue: 0.88)
        }
    }
}

struct CloseReadingControl: View {
    let model: ReaderModel
    let openSettings: () -> Void
    @State private var legend = false

    var body: some View {
        if let id = model.selectedPaperID {
            HStack(spacing: 6) {
                if model.closeReadingPaperID == id {
                    ProgressView().controlSize(.small)
                    Text(model.closeReadingProgress).font(.caption).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .quickStartTarget(.assistant)
                    Button {
                        model.closeReadingTask?.cancel()
                    } label: {
                        ReaderActionSymbol("stop.circle")
                    }
                    .help("停止精读").accessibilityLabel("停止精读")
                } else {
                    Button {
                        if model.existingCloseReading(for: id) == nil && (try? model.modelSettings.normalized()) == nil
                        {
                            openSettings()
                        } else {
                            Task { await model.showCloseReading(id) }
                        }
                    } label: {
                        Label(
                            model.existingCloseReading(for: id) == nil ? "AI 精读" : "查看精读",
                            systemImage: "text.magnifyingglass"
                        ).labelStyle(ReaderSymbolLabelStyle(motion: .lens))
                    }.disabled(model.busyAI)
                        .quickStartTarget(.assistant)
                    if model.existingCloseReading(for: id) != nil {
                        Button {
                            Task { await model.showCloseReading(id, regenerate: true) }
                        } label: {
                            ReaderActionSymbol("arrow.clockwise")
                        }.disabled(model.busyAI).help("重新精读").accessibilityLabel("重新精读")
                    }
                    Spacer()
                    Button {
                        legend.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            ForEach(CloseReadingDimension.allCases, id: \.self) { dimension in
                                Circle().fill(dimension.swatch).readerSymbolInk().frame(width: 8, height: 8)
                            }
                        }.padding(.vertical, 7).contentShape(Rectangle())
                    }.help("精读批注图例").accessibilityLabel("精读批注图例")
                        .popover(isPresented: $legend) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(CloseReadingDimension.allCases, id: \.self) { dimension in
                                    Label {
                                        Text(dimension.title)
                                    } icon: {
                                        Circle().fill(dimension.swatch).frame(width: 10, height: 10)
                                    }
                                }
                            }.font(.callout).foregroundStyle(ReaderTheme.ink).padding()
                                .readerPopupSurface()
                        }
                }
            }.readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.ink).font(.callout)
                .padding(.horizontal, 20).padding(.vertical, 9)
            Divider()
        }
    }
}

struct CloseReadingNoteList: View {
    let ids: [UUID]
    let model: ReaderModel
    let didNavigate: () -> Void
    @State private var expanded = false

    var body: some View {
        let byID = Dictionary(model.currentReadingNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let notes = ids.compactMap { byID[$0] }
        DisclosureGroup("段落批注 · \(notes.count)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(notes) { note in
                    Button {
                        model.openReadingNote(note)
                        didNavigate()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(note.dimension?.swatch ?? ReaderTheme.muted).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.dimension?.title ?? "阅读笔记").font(.caption.weight(.medium))
                                Text(ReadingNoteSummary.excerpt(note.anchors.first?.text ?? "")).font(.caption)
                                    .lineLimit(2)
                            }
                            Spacer()
                            ReaderActionSymbol("chevron.forward").imageScale(.small)
                        }.contentShape(Rectangle()).padding(.vertical, 7)
                    }.readerIconButtonStyle(.plain)
                }
            }
        }.font(.caption).tint(ReaderTheme.muted).foregroundStyle(ReaderTheme.ink)
    }
}
