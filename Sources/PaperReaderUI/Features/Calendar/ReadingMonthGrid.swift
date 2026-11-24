import PaperReaderKit
import SwiftUI

struct ReadingMonthGrid: View {
    @Binding var selection: Date
    let entries: [ReadingEntry]
    @State private var displayedMonth = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar = Calendar.current
    private var monthStart: Date { calendar.dateInterval(of: .month, for: displayedMonth)!.start }
    private var leadingDays: Int { (calendar.component(.weekday, from: monthStart) + 5) % 7 }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: monthStart)!.count }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Text(monthStart.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.opacity)
                    .animation(ReaderMotion.feedback(reduceMotion), value: monthStart)
                Spacer()
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left").readerSymbolInk()
                }
                .accessibilityLabel("上个月")
                Button {
                    selection = Date()
                    displayedMonth = selection
                } label: {
                    Text("今")
                }
                .accessibilityLabel("今天")
                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right").readerSymbolInk()
                }
                .accessibilityLabel("下个月")
            }.readerIconButtonStyle(.plain).font(.caption).foregroundStyle(ReaderTheme.ink)
            VStack(spacing: 5) {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { value in
                        Text(value).font(.caption2).foregroundStyle(ReaderTheme.muted).frame(height: 20)
                    }
                }
                ZStack {
                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(0..<42, id: \.self) { index in
                            if index < leadingDays || index >= leadingDays + dayCount {
                                Color.clear.frame(height: 34)
                            } else {
                                dayButton(index - leadingDays + 1)
                            }
                        }
                    }
                    .id(monthStart)
                    .transition(.opacity)
                }
                .animation(ReaderMotion.disclosure(reduceMotion), value: monthStart)
            }
        }
        .onAppear { displayedMonth = selection }
        .onChange(of: selection) { _, value in displayedMonth = value }
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 3), count: 7) }

    private func dayButton(_ number: Int) -> some View {
        let date = calendar.date(byAdding: .day, value: number - 1, to: monthStart)!
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let today = calendar.isDateInToday(date)
        let interval = calendar.dateInterval(of: .day, for: date)!
        let hasReading = entries.contains { $0.start < interval.end && $0.end > interval.start }
        return Button {
            selection = date
        } label: {
            VStack(spacing: 3) {
                Text("\(number)").font(.system(size: 12, weight: today || selected ? .semibold : .regular))
                Circle().fill(hasReading ? (selected ? .white : ReaderTheme.accent) : .clear).frame(width: 3, height: 3)
            }.frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(selected ? .white : today ? ReaderTheme.accent : ReaderTheme.ink)
                .background(selected ? ReaderTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                .animation(ReaderMotion.feedback(reduceMotion), value: selected)
        }.buttonStyle(.plain)
            .accessibilityLabel(date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))
            .accessibilityValue(
                [selected ? "已选择" : "", hasReading ? "有阅读记录" : ""].filter { !$0.isEmpty }.joined(separator: "，"))
    }

    private func moveMonth(_ offset: Int) {
        if let value = calendar.date(byAdding: .month, value: offset, to: monthStart) { displayedMonth = value }
    }
}
