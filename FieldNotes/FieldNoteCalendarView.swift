import CoreData
import SwiftUI

struct FieldNoteCalendarView: View {
    @Environment(\.calendar) private var calendar
    @FetchRequest(sortDescriptors: [SortDescriptor(\.createdAt, order: .reverse)]) private var notes: FetchedResults<FieldNoteEntity>

    let audioManager: AudioRecorderManager

    @State private var displayedMonth: Date?
    @State private var selectedDay: Date?

    private let dayColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4), count: 7)
    private let galleryColumns = [GridItem(.adaptive(minimum: 135), spacing: 12, alignment: .top)]

    private var month: Date {
        let date = displayedMonth ?? notes.first?.createdAt ?? .now
        return calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    var body: some View {
        let interval = calendar.dateInterval(of: .month, for: month)
        let monthNotes = notes.filter { note in
            guard let date = note.createdAt, let interval else { return false }
            return date >= interval.start && date < interval.end
        }
        let notesByDay = monthNotes.reduce(into: [Date: [FieldNoteEntity]]()) { days, note in
            if let date = note.createdAt {
                days[calendar.startOfDay(for: date), default: []].append(note)
            }
        }
        let undatedNotes = notes.filter { $0.createdAt == nil }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 10) {
                    monthHeader
                    monthGrid(notesByDay: notesByDay)
                }

                monthGallery(selectedDay.map { notesByDay[$0, default: []] } ?? monthNotes)

                if !undatedNotes.isEmpty {
                    DisclosureGroup {
                        gallery(undatedNotes)
                            .padding(.top, 8)
                    } label: {
                        Text("Undated (\(undatedNotes.count))").font(AppFont.headline)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Calendar")
                    .font(AppFont.headline)
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Button("Previous Month", systemImage: "chevron.backward") {
                stepMonth(by: -1)
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)

            Menu {
                Button("Current Month") { showMonth(containing: .now) }
                ForEach(monthsWithNotes, id: \.self) { date in
                    Button {
                        showMonth(containing: date)
                    } label: {
                        Text(date, format: .dateTime.month(.wide).year())
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(month, format: .dateTime.month(.wide).year())
                        .font(AppFont.headline)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityHint("Choose a month with notes")

            Button("Next Month", systemImage: "chevron.forward") {
                stepMonth(by: 1)
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    private var monthsWithNotes: [Date] {
        let months = notes.compactMap { note in
            note.createdAt.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
        }
        return Set(months).sorted(by: >)
    }

    private func monthGrid(notesByDay: [Date: [FieldNoteEntity]]) -> some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstWeekday = calendar.firstWeekday
        let weekday = calendar.component(.weekday, from: month)
        let leadingDays = (weekday - firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
        let days = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }

        return LazyVGrid(columns: dayColumns, spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                Text(symbols[(firstWeekday - 1 + index) % 7])
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            ForEach(0..<leadingDays, id: \.self) { _ in
                Color.clear.frame(height: 44)
                    .accessibilityHidden(true)
            }
            ForEach(days, id: \.self) { day in
                let date = calendar.startOfDay(for: day)
                let dayNotes = notesByDay[date, default: []]
                Button {
                    displayedMonth = month
                    selectedDay = selectedDay == date ? nil : date
                } label: {
                    CalendarDayTile(
                        number: calendar.component(.day, from: date),
                        imagePath: dayNotes.first?.imagePath,
                        count: dayNotes.count,
                        isToday: calendar.isDateInToday(date),
                        isSelected: selectedDay == date
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).month(.wide).day().year()))
                .accessibilityValue(Text("\(dayNotes.count) notes"))
                .accessibilityAddTraits(selectedDay == date ? .isSelected : [])
            }
        }
    }

    private func monthGallery(_ visibleNotes: [FieldNoteEntity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let selectedDay {
                    Text(selectedDay, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    Spacer()
                    Button("Show Month") { self.selectedDay = nil }
                        .font(AppFont.caption)
                } else {
                    Text("Notes")
                }
            }
            .font(AppFont.headline)

            if visibleNotes.isEmpty {
                Text(selectedDay == nil ? "No notes this month." : "No notes on this day.")
                    .foregroundStyle(.secondary)
            } else {
                gallery(visibleNotes)
            }
        }
    }

    private func gallery(_ visibleNotes: [FieldNoteEntity]) -> some View {
        LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 14) {
            ForEach(visibleNotes) { note in
                NavigationLink {
                    FieldCard(note: note, audioManager: audioManager)
                        .navigationTitle("Field Note")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        CalendarCover(imagePath: note.imagePath, maxPixelSize: 600)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(alignment: .bottomTrailing) {
                                if note.audioFileName != nil {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .padding(6)
                                        .foregroundStyle(.white)
                                        .background(.black.opacity(0.75), in: .capsule)
                                        .padding(6)
                                        .accessibilityLabel("Audio included")
                                }
                            }
                        Text(note.caption.isEmpty ? "Field Note" : note.caption)
                            .font(AppFont.caption)
                            .lineLimit(2)
                        if let date = note.createdAt {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(AppFont.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stepMonth(by offset: Int) {
        guard let date = calendar.date(byAdding: .month, value: offset, to: month) else { return }
        showMonth(containing: date)
    }

    private func showMonth(containing date: Date) {
        displayedMonth = date
        selectedDay = nil
    }
}

private struct CalendarDayTile: View {
    let number: Int
    let imagePath: String?
    let count: Int
    let isToday: Bool
    let isSelected: Bool

    private var dayNumberColor: Color {
        if imagePath != nil { return .white }
        return isToday ? .accentColor : .primary
    }

    var body: some View {
        CalendarCover(imagePath: imagePath, maxPixelSize: 192, heightRange: 44...64)
            .overlay(alignment: .topLeading) {
                Text(number, format: .number)
                    .foregroundStyle(dayNumberColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(imagePath == nil ? .clear : .black.opacity(0.75), in: .capsule)
                    .padding(2)
            }
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text("+\(count - 1)")
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.75), in: .capsule)
                        .padding(2)
                }
            }
            .font(AppFont.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .clipShape(.rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected || isToday ? Color.accentColor : .clear, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect)
    }
}

private struct CalendarCover: View {
    let imagePath: String?
    let maxPixelSize: Int
    var heightRange: ClosedRange<CGFloat>? = nil

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, minHeight: heightRange?.lowerBound, maxHeight: heightRange?.upperBound)
            .background(.primary.opacity(0.06))
            .overlay {
                if let imagePath {
                    NoteImageView(imagePath: imagePath, thumbnailPixelSize: maxPixelSize)
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

#Preview("Calendar") {
    NavigationStack {
        FieldNoteCalendarView(audioManager: AudioRecorderManager())
    }
    .font(AppFont.body)
    .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
