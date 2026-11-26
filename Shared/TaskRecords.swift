import Foundation

enum StorageError: Error {
    case unavailable, invalidImage, invalidTemplate, full, needsPro, missing, blankPurpose, multipleImages
    var message: String {
        switch self {
        case .unavailable: return L.t("error.storage")
        case .invalidImage: return L.t("error.image")
        case .invalidTemplate: return L.t("error.template")
        case .full: return L.t("error.full")
        case .needsPro: return L.t("error.pro")
        case .missing: return L.t("error.missing")
        case .blankPurpose: return L.t("error.purpose")
        case .multipleImages: return L.t("error.multiple")
        }
    }
}

struct ScreenshotTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var purpose: String
    var due: DueDate
    var repeatRule: RepeatRule = .never
    var createdAt: Date
    var completedAt: Date?
    var firstCompletedAt: Date?
    var reviewCompletionDay: CivilDay?
    var image: UUID?
    var fingerprint: String?
    var sourceAsset: String?
    var reminderVersion = UUID()

    static func purpose(_ text: String) throws -> String {
        let trimmed = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StorageError.blankPurpose }
        return String(trimmed.prefix(80))
    }
}

enum ReviewChoice: String, Codable {
    case keep, pendingDelete, madeTask
}

struct ReviewAction: Codable {
    var asset: String
    var choice: ReviewChoice
    var newTask: UUID?
    var originalPurpose: String?
    var originalDue: DueDate?
}

struct ProgressCounts: Equatable {
    var cleared: Int
    var done: Int
}

struct TaskState: Codable {
    var entitlement: Entitlement?
    var tasks: [ScreenshotTask] = []
    var importTokens: [UUID: UUID] = [:]
    var review: [String: ReviewChoice] = [:]
    var lastReview: ReviewAction?
    var deletedAssets: [String: Date] = [:]
    var deletionInFlight: [String] = []
    var milestonePending = false
    var notificationPreview = false
    var dailySummary = true
    var widgetThumbnails = true
    var trialNoticeSeen = false
    var shareNoticeSeen = false
    var scheduledFirst: [String: Date] = [:]
    var remindersDirty = true
    var reminderRevision = UUID()
    var useDays: Set<CivilDay> = []
    var reviewVersion: String?
    var templates: [TemplateItem] = []

    func hasPro(at now: Date = .now) -> Bool { entitlement?.hasPro(at: now) ?? Launch.freePeriod }
    var openCount: Int { tasks.filter { $0.completedAt == nil }.count }
    var basket: [String] { review.filter { $0.value == .pendingDelete }.map(\.key).sorted() }

    func openTasks() -> [ScreenshotTask] {
        tasks.filter { $0.completedAt == nil }.sorted {
            let a = ($0.due.day, $0.due.hour, $0.due.minute, $0.createdAt)
            let b = ($1.due.day, $1.due.hour, $1.due.minute, $1.createdAt)
            return a < b
        }
    }

    func sections(at now: Date, calendar: Calendar) -> (today: [ScreenshotTask], next: [ScreenshotTask]) {
        let day = CivilDay(now, calendar: calendar)
        let sorted = openTasks()
        return (sorted.filter { $0.due.day <= day }, sorted.filter { $0.due.day > day })
    }

    func progress(at now: Date = .now, calendar: Calendar = .current) -> ProgressCounts {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return .init(cleared: 0, done: 0) }
        let completed = tasks.filter { task in
            task.completedAt != nil && task.firstCompletedAt.map { $0 >= week.start && $0 < week.end } == true
        }.count
        return .init(cleared: deletedAssets.values.filter { $0 >= week.start && $0 < week.end }.count, done: completed)
    }

    func hasReviewCompletion(on day: CivilDay) -> Bool {
        tasks.contains { $0.completedAt != nil && $0.reviewCompletionDay == day }
    }

    func isReviewEligible(version: String, on day: CivilDay) -> Bool {
        reviewVersion != version && hasReviewCompletion(on: day)
    }

    mutating func markRemindersDirty() {
        remindersDirty = true
        reminderRevision = UUID()
    }
}
