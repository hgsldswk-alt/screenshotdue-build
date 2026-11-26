import SwiftUI
import UIKit
import WidgetKit

private struct WidgetEntry: TimelineEntry {
    let date: Date
    let data: TodayWidgetData
}

private struct DueTimeline: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, data: TodayWidgetData(enabled: true, count: 0, nextTime: nil, rows: []))
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let lock = context.family == .accessoryRectangular
        DispatchQueue.global(qos: .utility).async {
            let store = try? TaskStore.shared()
            let state = (try? store?.snapshot()) ?? TaskState()
            completion(entry(state: state, at: .now, store: store, lock: lock))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let lock = context.family == .accessoryRectangular
        DispatchQueue.global(qos: .utility).async {
            let now = Date.now
            let store = try? TaskStore.shared()
            let state = (try? store?.snapshot()) ?? TaskState()
            let calendar = CivilDay.calendar()
            let tomorrow = CivilDay(now, calendar: calendar).adding(1, in: calendar).date(in: calendar)
            let afterTomorrow = CivilDay(tomorrow, calendar: calendar).adding(1, in: calendar).date(in: calendar)
            var dates = Set([now, tomorrow])
            let todayTimes = Set(state.sections(at: now, calendar: calendar).today
                .map { $0.due.date(in: calendar) }.filter { $0 > now && $0 < tomorrow }).sorted()
            dates.formUnion(todayTimes.prefix(8))
            if let entitlement = state.entitlement, !entitlement.purchasedPro,
               entitlement.trialEnd > now, entitlement.trialEnd < afterTomorrow {
                dates.insert(entitlement.trialEnd)
            }
            var thumbnails: [UUID: UIImage] = [:]
            let entries = dates.sorted().map { date in
                let data = TodayWidgetData.prepare(state: state, at: date) { id in
                    guard !lock, let store else { return nil }
                    if let image = thumbnails[id] { return image }
                    let image = PhotoData.image(at: store.imageURL(id, thumbnail: true), edge: 75)
                    thumbnails[id] = image
                    return image
                }
                return WidgetEntry(date: date, data: data)
            }
            completion(Timeline(entries: entries, policy: .after(todayTimes.dropFirst(8).first ?? tomorrow)))
        }
    }

    private func entry(state: TaskState, at date: Date, store: TaskStore?, lock: Bool) -> WidgetEntry {
        WidgetEntry(date: date, data: TodayWidgetData.prepare(state: state, at: date) { id in
            guard !lock, let store else { return nil }
            return PhotoData.image(at: store.imageURL(id, thumbnail: true), edge: 75)
        })
    }
}

private struct DueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        TodayWidgetPanel(data: entry.data, lock: family == .accessoryRectangular,
                         limit: family == .systemMedium ? 3 : 2)
            .widgetURL(URL(string: "screenshotdue://today"))
            .containerBackground(Theme.background, for: .widget)
    }
}

@main
struct ScreenshotDueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScreenshotDueToday", provider: DueTimeline()) { entry in
            DueWidgetView(entry: entry)
        }
        .configurationDisplayName(L.t("widget.guide"))
        .description(L.t("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
