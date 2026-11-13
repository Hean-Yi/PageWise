import PaperReaderKit
import SwiftUI

struct ReadingCalendarView: View {
    @Bindable var model: ReaderModel
    @State private var date = Date()
    @State private var showAdd = false
    @State private var minutes = 20.0
    @State private var addPaper: UUID?
    private var day: DateInterval { Calendar.current.dateInterval(of: .day, for: date)! }
    private var entries: [ReadingEntry] { model.state.reading.filter { $0.start < day.end && $0.end > day.start } }
    private var readingMinutes: Int { Int(ReadingMetrics.seconds(entries, during: day) / 60) }
    private var paperCount: Int { Set(entries.map(\.paperID)).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center) {
                    Text("阅读日历").font(.system(size: 32, weight: .regular, design: .serif))
                    Spacer()
                    Button {
                        addPaper = model.selectedPaperID ?? model.state.papers.first?.id
                        showAdd = true
                    } label: {
                        Label("补记", systemImage: "plus")
                    }
                    .buttonStyle(.bordered).disabled(model.state.papers.isEmpty)
                    .accessibilityLabel("补记阅读记录")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        calendarCard.frame(width: 340)
                        statistics.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        calendarCard
                        statistics
                    }
                }
                HStack {
                    Text("当日阅读").font(.headline)
                    Spacer()
                    Text("\(entries.count) 条记录").font(.caption).foregroundStyle(ReaderTheme.muted)
                }.padding(.top, 8)
                if entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "book.closed").font(.system(size: 32, weight: .light))
                        Text("暂无阅读记录").font(.subheadline)
                    }
                    .foregroundStyle(ReaderTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(entries.sorted { $0.start > $1.start }) { entry in
                            timelineRow(entry)
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    Picker("论文", selection: $addPaper) {
                        ForEach(model.state.papers) { Text($0.title).tag(Optional($0.id)) }
                    }
                    DatePicker("开始时间", selection: $date)
                    Stepper("阅读 \(Int(minutes)) 分钟", value: $minutes, in: 1...480, step: 5)
                }.padding().navigationTitle("补记阅读")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if let addPaper { model.addReading(paperID: addPaper, date: date, minutes: minutes) }
                                showAdd = false
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showAdd = false } }
                    }
            }
            .tint(ReaderTheme.accent)
            #if os(macOS)
                .frame(minWidth: 380, minHeight: 250)
            #endif
        }
    }

    private var calendarCard: some View {
        ReadingMonthGrid(selection: $date, entries: model.state.reading)
            .padding(20).frame(maxWidth: .infinity)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ReaderTheme.line))
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.subheadline).foregroundStyle(ReaderTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(readingMinutes)")
                    .font(.system(size: 64, weight: .regular, design: .serif))
                    .foregroundStyle(ReaderTheme.accent)
                    .monospacedDigit()
                Text("分钟").font(.subheadline).foregroundStyle(ReaderTheme.muted)
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(paperCount)").font(.system(size: 32, weight: .regular, design: .serif)).monospacedDigit()
                Text("篇论文").font(.subheadline).foregroundStyle(ReaderTheme.muted)
                Spacer()
                Image(systemName: "book.pages").font(.system(size: 24, weight: .light))
                    .foregroundStyle(ReaderTheme.accent.opacity(0.55)).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            Text("估计时长").font(.caption2).foregroundStyle(ReaderTheme.muted)
        }.padding(22)
    }

    private func timelineRow(_ entry: ReadingEntry) -> some View {
        let title = model.state.papers.first { $0.id == entry.paperID }?.title ?? "论文"
        return HStack(alignment: .top, spacing: 12) {
            Text(entry.start.formatted(date: .omitted, time: .shortened))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(ReaderTheme.muted)
                .frame(width: 54, alignment: .trailing).padding(.top, 21)
            Circle().fill(ReaderTheme.accent).frame(width: 6, height: 6).padding(.top, 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(
                        entry.end.timeIntervalSince(entry.start) < 60
                            ? "不足 1 分钟" : "\(Int(entry.end.timeIntervalSince(entry.start) / 60)) 分钟")
                    if entry.manual {
                        Text("补记").padding(.horizontal, 6).padding(.vertical, 2)
                            .background(ReaderTheme.canvas, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.select(entry.paperID)
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .accessibilityLabel("阅读\(title)").help("打开论文")
                    Button(role: .destructive) {
                        model.deleteReading(entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除阅读记录").help("删除记录")
                }
                .font(.caption).foregroundStyle(ReaderTheme.muted).buttonStyle(.borderless)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
        }
    }
}

struct MemoryView: View {
    @Bindable var model: ReaderModel
    private var memories: [MemoryItem] { model.state.memories.filter { !$0.deleted } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("研究记忆").font(.system(size: 32, weight: .regular, design: .serif))
                    Text("\(memories.count)").font(.system(.title3, design: .monospaced))
                        .foregroundStyle(ReaderTheme.muted)
                    Spacer()
                }
                if memories.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "brain.head.profile").font(.system(size: 42, weight: .ultraLight))
                        Text("从一次讨论开始").font(.headline)
                        Button {
                            model.select(model.selectedPaperID ?? model.state.papers.first?.id)
                        } label: {
                            Label("去阅读", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.borderless).foregroundStyle(ReaderTheme.accent).font(.caption)
                    }
                    .foregroundStyle(ReaderTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(memories) { memory in
                            memoryCard(memory)
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
    }

    private func memoryCard(_ memory: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField(
                "研究关注点",
                text: Binding(
                    get: { model.state.memories.first { $0.id == memory.id }?.text ?? "" },
                    set: { model.updateMemory(id: memory.id, text: $0) }), axis: .vertical
            )
            .textFieldStyle(.plain).font(.system(size: 16)).lineSpacing(5)
            .accessibilityLabel("编辑研究记忆")
            HStack(spacing: 14) {
                Label(memory.userEdited ? "已编辑" : "自动整理", systemImage: memory.userEdited ? "pencil" : "sparkle")
                    .font(.caption)
                Spacer()
                if let source = model.state.chats.first(where: { $0.id == memory.sourceID }) {
                    Button {
                        model.select(source.paperID)
                    } label: {
                        Label("来源", systemImage: "arrow.up.right")
                    }.help("打开来源论文")
                }
                Button(role: .destructive) {
                    model.deleteMemory(memory.id)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除此条记忆").help("删除记忆")
            }
            .font(.caption).foregroundStyle(ReaderTheme.muted).buttonStyle(.borderless)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line))
    }
}
