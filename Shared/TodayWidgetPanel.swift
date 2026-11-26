import SwiftUI
import UIKit

struct TodayWidgetData {
    let enabled: Bool
    let count: Int
    let nextTime: String?
    let rows: [Row]

    struct Row: Identifiable {
        let id: UUID
        let purpose: String
        let time: String
        let thumbnail: UIImage?
    }

    static func prepare(state: TaskState, at date: Date, readThumbnail: (UUID) -> UIImage?) -> Self {
        let tasks = state.sections(at: date, calendar: CivilDay.calendar()).today
        let nextTime = tasks.first { $0.due.day == CivilDay(date) && $0.due.date(in: CivilDay.calendar()) > date }
            .map { DateText.clock($0.due) }
        let enabled = state.hasPro(at: date)
        let rows = enabled ? tasks.prefix(3).map { task in
            Row(id: task.id, purpose: task.purpose, time: DateText.short(task.due, now: date),
                thumbnail: state.widgetThumbnails ? task.image.flatMap(readThumbnail) : nil)
        } : []
        return Self(enabled: enabled, count: enabled ? tasks.count : 0, nextTime: enabled ? nextTime : nil, rows: rows)
    }
}

struct TodayWidgetPanel: View {
    let data: TodayWidgetData
    let lock: Bool
    var limit = 2

    var body: some View {
        if lock {
            VStack(alignment: .leading, spacing: 2) {
                if !data.enabled {
                    Text(L.t("widget.locked")).font(.caption)
                } else if data.count == 0 {
                    Text(L.t("home.emptyToday")).font(.caption)
                } else {
                    Text(L.f("widget.count", data.count)).font(.headline).privacySensitive()
                    if let time = data.nextTime { Text(L.f("widget.nextTime", time)).font(.caption).privacySensitive() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Label(L.t("home.today"), systemImage: "checkmark.circle").font(.headline)
                if !data.enabled {
                    Text(L.t("widget.locked")).font(.caption)
                } else if data.count == 0 {
                    Text(L.t("home.emptyToday")).font(.caption)
                } else {
                    ForEach(data.rows.prefix(limit)) { row in
                        HStack(spacing: 7) {
                            if let thumbnail = row.thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                                    .frame(width: 26, height: 25).clipShape(RoundedRectangle(cornerRadius: 4))
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.purpose).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(row.time).font(.caption2).lineLimit(1)
                            }
                        }
                        .privacySensitive()
                    }
                    if data.count > limit {
                        Text(L.f("widget.more", data.count - limit)).font(.caption2).privacySensitive()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
