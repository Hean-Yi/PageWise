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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每一次阅读，都留下痕迹。").font(.system(.largeTitle, design: .serif))
                        Text("自动记录前台阅读，支持补记与修正。时长为估计值。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("补记阅读") {
                        addPaper = model.selectedPaperID ?? model.state.papers.first?.id
                        showAdd = true
                    }.disabled(model.state.papers.isEmpty)
                }
                HStack(alignment: .top, spacing: 30) {
                    DatePicker("选择日期", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).frame(
                        maxWidth: 350)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(date.formatted(date: .complete, time: .omitted)).font(.headline)
                        Text("\(Int(ReadingMetrics.seconds(entries, during: day) / 60)) 分钟")
                            .font(.system(size: 44, weight: .light, design: .rounded)).foregroundStyle(.teal)
                        Text("\(Set(entries.map(\.paperID)).count) 篇论文 · 重叠时段不重复计时").font(.callout).foregroundStyle(
                            .secondary)
                    }.padding(.top, 20)
                }
                if entries.isEmpty {
                    ContentUnavailableView("这一天尚无阅读记录", systemImage: "calendar", description: Text("打开论文开始阅读，或手动补记。"))
                }
                ForEach(entries.sorted { $0.start > $1.start }) { entry in
                    HStack {
                        Image(systemName: "doc.text").font(.title2).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.state.papers.first { $0.id == entry.paperID }?.title ?? "论文").font(.headline)
                            Text(
                                "\(entry.start.formatted(date: .omitted, time: .shortened)) · \(max(1, Int(entry.end.timeIntervalSince(entry.start) / 60))) 分钟 · \(entry.manual ? "手动补记" : "自动记录")"
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("阅读") { model.select(entry.paperID) }
                        Button(role: .destructive) {
                            model.deleteReading(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }.help("删除此条记录后可重新补记")
                    }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(32).frame(maxWidth: 1000, alignment: .leading)
        }.sheet(isPresented: $showAdd) {
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
            }.frame(minWidth: 380, minHeight: 250)
        }
    }
}

struct MemoryView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("研究记忆").font(.system(.largeTitle, design: .serif))
                Text("自动保存讨论中的研究关注点。每条都有来源，可修改或删除；它们用于理解你的背景，不作为论文事实。")
                    .foregroundStyle(.secondary)
                if model.state.memories.allSatisfy(\.deleted) {
                    ContentUnavailableView(
                        "记忆从讨论开始", systemImage: "brain.head.profile", description: Text("阅读论文并提问后，这里会自动整理你关注的问题。"))
                }
                ForEach(model.state.memories.filter { !$0.deleted }) { memory in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(
                            "研究关注点",
                            text: Binding(
                                get: { model.state.memories.first { $0.id == memory.id }?.text ?? "" },
                                set: { model.updateMemory(id: memory.id, text: $0) }), axis: .vertical
                        )
                        .textFieldStyle(.plain).font(.body)
                        HStack {
                            Text(memory.userEdited ? "已由你修正" : "来自阅读讨论 · 自动记录").font(.caption).foregroundStyle(
                                .secondary)
                            Spacer()
                            if let source = model.state.chats.first(where: { $0.id == memory.sourceID }) {
                                Button("查看来源") { model.select(source.paperID) }
                            }
                            Button(role: .destructive) {
                                model.deleteMemory(memory.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }.buttonStyle(.borderless)
                    }.padding(18).background(.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(32).frame(maxWidth: 900, alignment: .leading)
        }
    }
}
