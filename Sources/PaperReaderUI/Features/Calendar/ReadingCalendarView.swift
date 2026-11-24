import PaperReaderKit
import SwiftUI

struct ReadingCalendarView: View {
    @Bindable var model: ReaderModel
    @Binding var date: Date
    @State private var showAdd = false
    @State private var minutes = 20.0
    @State private var addPaper: UUID?
    private var day: DateInterval { Calendar.current.dateInterval(of: .day, for: date)! }

    var body: some View {
        let activity = ReadingMetrics.dailyActivity(model.state.reading, during: day)
        let stats = statistics(minutes: Int(activity.seconds / 60), paperCount: activity.papers.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center) {
                    Text("阅读日历").font(.system(size: 32, weight: .regular, design: .serif))
                    Spacer()
                    Button {
                        addPaper = model.selectedPaperID ?? model.state.papers.first?.id
                        showAdd = true
                    } label: {
                        Label("补记", readerIcon: .add, size: 15)
                    }
                    .readerIconButtonStyle(.bordered).disabled(model.state.papers.isEmpty)
                    .accessibilityLabel("补记阅读记录")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        calendarCard.frame(width: 340)
                        stats.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        calendarCard
                        stats
                    }
                }
                HStack {
                    Text("当日阅读").font(.headline)
                    Spacer()
                    Text("\(activity.papers.count) 篇").font(.caption).foregroundStyle(ReaderTheme.muted)
                }.padding(.top, 8)
                if activity.papers.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "book.closed").font(.system(size: 32, weight: .light))
                        Text("暂无阅读记录").font(.subheadline)
                    }
                    .foregroundStyle(ReaderTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(activity.papers) { paper in
                            timelineRow(paper)
                        }
                    }
                    .id(day.start)
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

    private func statistics(minutes: Int, paperCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.subheadline).foregroundStyle(ReaderTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(minutes)")
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

    private func timelineRow(_ paper: ReadingMetrics.PaperActivity) -> some View {
        let title = model.state.papers.first { $0.id == paper.id }?.title ?? "论文"
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                Spacer()
                Button {
                    model.select(paper.id)
                } label: {
                    Image(systemName: "arrow.up.right").readerSymbolInk()
                }
                .readerIconButtonStyle(.borderless).accessibilityLabel("阅读\(title)").help("打开论文")
            }
            DisclosureGroup {
                ForEach(paper.entries) { record in
                    recordDetail(record)
                }
            } label: {
                HStack {
                    Text(durationText(paper.seconds))
                    Spacer()
                    Text("\(paper.entries.count) 条明细")
                }
            }
            .font(.caption).foregroundStyle(ReaderTheme.muted)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
    }

    private func recordDetail(_ record: ReadingEntry) -> some View {
        let start = max(day.start, record.start)
        let end = min(day.end, record.end)
        let endTime = end == day.end ? "24:00" : end.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 8) {
            Text("\(start.formatted(date: .omitted, time: .shortened)) – \(endTime)").monospacedDigit()
            if record.manual { Text("补记") }
            Spacer()
            Text(durationText(end.timeIntervalSince(start)))
            Button(role: .destructive) {
                model.deleteReading(record.id)
            } label: {
                ReaderIcon(.delete, size: 15).readerIconTarget(macOS: 24)
            }
            .readerIconButtonStyle(.borderless).accessibilityLabel("删除阅读记录").help("删除记录")
        }
        .padding(.vertical, 3)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "不足 1 分钟" : "\(Int(seconds / 60)) 分钟"
    }
}
