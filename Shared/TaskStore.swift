import Foundation
import SQLite3

struct TaskStore: Sendable {
    let directory: URL
    private var database: URL { directory.appendingPathComponent("tasks.sqlite3") }
    private var images: URL { directory.appendingPathComponent("Images", isDirectory: true) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func shared() throws -> Self {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Launch.appGroup) else {
            throw StorageError.unavailable
        }
        return TaskStore(directory: container.appendingPathComponent("ScreenshotDue", isDirectory: true))
    }

    func imageURL(_ id: UUID, thumbnail: Bool) -> URL {
        images.appendingPathComponent(id.uuidString + (thumbnail ? ".jpg" : ".original"))
    }

    private func connect(readOnly: Bool) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(database.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw StorageError.unavailable
        }
        sqlite3_busy_timeout(handle, 5000)
        return handle
    }

    private func run(_ sql: String, _ handle: OpaquePointer) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw StorageError.unavailable }
    }

    private func read(_ handle: OpaquePointer) throws -> TaskState {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM state WHERE id = 1", -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return TaskState() }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw StorageError.unavailable
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(TaskState.self, from: data)
    }

    func snapshot() throws -> TaskState {
        guard FileManager.default.fileExists(atPath: database.path) else { return TaskState() }
        let handle = try connect(readOnly: true)
        defer { sqlite3_close(handle) }
        return try read(handle)
    }

    private func persist(_ state: TaskState, _ handle: OpaquePointer) throws {
        let data = try JSONEncoder().encode(state)
        var statement: OpaquePointer?
        guard data.count <= Int(Int32.max),
              sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO state (id, payload) VALUES (1, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        let binding = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), Self.transient) }
        guard binding == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw StorageError.unavailable }
    }

    @discardableResult
    func change<T>(staged: UUID? = nil, _ update: (inout TaskState) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let handle = try connect(readOnly: false)
        defer { sqlite3_close(handle) }
        try run("BEGIN IMMEDIATE", handle)
        do {
            try run("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)", handle)
            var state = try read(handle)
            let result = try update(&state)
            try persist(state, handle)
            try run("COMMIT", handle)
            return result
        } catch {
            if let staged { discardImage(staged) }
            try? run("ROLLBACK", handle)
            throw error
        }
    }

    func bootstrap(now: Date = .now, test: Bool = false, expired: Bool = false, purchased: Bool = false) throws -> TaskState {
        try change { state in
            if state.entitlement == nil {
                let first: Date
                if test {
                    first = expired ? now.addingTimeInterval(-31 * 86_400) : now
                } else {
                    first = try TrialKeychain.firstOpen(now: now)
                }
                state.entitlement = Entitlement(firstOpen: first, proStartedAt: first, purchasedPro: purchased)
            }
            return state
        }
    }

    func purgeUnusedFiles() throws {
        try change { state in
            let live = Set(state.tasks.compactMap(\.image).map(\.uuidString))
            let urls = try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)
            for url in urls where [".jpg", ".original"].contains("." + url.pathExtension) &&
                !live.contains(url.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func write(_ photo: PreparedPhoto, id: UUID) throws {
        try photo.original.write(to: imageURL(id, thumbnail: false), options: .atomic)
        try photo.thumbnail.write(to: imageURL(id, thumbnail: true), options: .atomic)
    }

    private func discardImage(_ id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(id, thumbnail: false))
        try? FileManager.default.removeItem(at: imageURL(id, thumbnail: true))
    }

    func add(_ photo: PreparedPhoto, token: UUID, purpose: String, due: DueDate,
             asset: String? = nil, now: Date = .now) throws -> UUID {
        let purpose = try ScreenshotTask.purpose(purpose)
        let image = UUID()
        return try change(staged: image) { state in
            if let existing = state.importTokens[token] { return existing }
            if let asset {
                guard state.hasPro(at: now) else { throw StorageError.needsPro }
                guard state.review[asset] == nil else { throw StorageError.missing }
            }
            if let existing = state.tasks.first(where: {
                $0.completedAt == nil && ($0.fingerprint == photo.fingerprint || (asset != nil && $0.sourceAsset == asset))
            }) {
                if let asset {
                    state.review[asset] = .madeTask
                    state.lastReview = ReviewAction(asset: asset, choice: .madeTask, newTask: nil)
                }
                state.importTokens[token] = existing.id
                return existing.id
            }
            guard state.entitlement?.canAdd(openCount: state.openCount, at: now) ?? false else {
                throw StorageError.full
            }
            try write(photo, id: image)
            let task = ScreenshotTask(purpose: purpose, due: due, createdAt: now, image: image,
                                      fingerprint: photo.fingerprint, sourceAsset: asset)
            state.tasks.append(task)
            state.importTokens[token] = task.id
            if let asset {
                state.review[asset] = .madeTask
                state.lastReview = ReviewAction(asset: asset, choice: .madeTask, newTask: task.id,
                                                originalPurpose: purpose, originalDue: due)
            }
            state.markRemindersDirty()
            return task.id
        }
    }

    func updateTask(_ id: UUID, _ update: (inout ScreenshotTask, Bool) throws -> Void) throws {
        try change { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw StorageError.missing }
            let old = state.tasks[index]
            let hasPro = state.hasPro()
            try update(&state.tasks[index], hasPro)
            if old.due != state.tasks[index].due {
                state.tasks[index].reminderVersion = UUID()
            }
            state.markRemindersDirty()
        }
    }

    func complete(_ id: UUID, done: Bool, now: Date = .now, calendar: Calendar = CivilDay.calendar()) throws {
        try change { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw StorageError.missing }
            let wasDone = state.tasks[index].completedAt != nil
            guard wasDone != done else { return }
            if done, state.tasks[index].firstCompletedAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
                state.tasks[index].firstCompletedAt = now
            }
            state.tasks[index].completedAt = done ? now : nil
            let day = CivilDay(now, calendar: calendar)
            if done { state.useDays.insert(day) }
            let qualifiesForReview = done && state.useDays.filter { $0 <= day }.count >= 3
            state.tasks[index].reviewCompletionDay = qualifiesForReview ? day : nil
            state.markRemindersDirty()
        }
    }

    struct ReviewClaim: Sendable {
        let version: String
        let previousVersion: String?
    }

    func claimReview(version: String, on day: CivilDay) throws -> ReviewClaim? {
        try change { state in
            guard state.isReviewEligible(version: version, on: day) else { return nil }
            let claim = ReviewClaim(version: version, previousVersion: state.reviewVersion)
            state.reviewVersion = version
            return claim
        }
    }

    func releaseReview(_ claim: ReviewClaim) throws {
        try change { state in
            if state.reviewVersion == claim.version { state.reviewVersion = claim.previousVersion }
        }
    }

    func replaceImage(_ id: UUID, photo: PreparedPhoto) throws {
        let image = UUID()
        let old: UUID? = try change(staged: image) { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw StorageError.missing }
            let old = state.tasks[index].image
            try write(photo, id: image)
            state.tasks[index].image = image
            state.tasks[index].fingerprint = photo.fingerprint
            return old
        }
        if let old { discardImage(old) }
    }

    func removeCopy(_ id: UUID) throws {
        let image: UUID? = try change { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id && $0.completedAt != nil }) else {
                throw StorageError.missing
            }
            let image = state.tasks[index].image
            state.tasks[index].image = nil
            state.tasks[index].fingerprint = nil
            return image
        }
        if let image { discardImage(image) }
    }

    func review(_ asset: String, choice: ReviewChoice) throws {
        try change { state in
            guard state.hasPro() else { throw StorageError.needsPro }
            guard state.review[asset] == nil, choice != .madeTask else { throw StorageError.missing }
            state.review[asset] = choice
            state.lastReview = ReviewAction(asset: asset, choice: choice, newTask: nil)
        }
    }

    func undoReview() throws {
        let image: UUID? = try change { state in
            guard let action = state.lastReview else { return nil }
            guard state.hasPro() || action.choice == .pendingDelete else { throw StorageError.needsPro }
            guard !state.deletionInFlight.contains(action.asset),
                  state.deletedAssets[action.asset] == nil, state.review[action.asset] == action.choice else {
                return nil
            }
            state.review[action.asset] = nil
            state.lastReview = nil
            guard let id = action.newTask, let index = state.tasks.firstIndex(where: {
                $0.id == id && $0.firstCompletedAt == nil && $0.sourceAsset == action.asset
            }) else { return nil }
            guard state.importTokens.values.filter({ $0 == id }).count == 1 else { return nil }
            let task = state.tasks[index]
            guard task.purpose == action.originalPurpose, task.repeatRule == .never,
                  task.due == action.originalDue else { return nil }
            state.tasks.remove(at: index)
            state.importTokens = state.importTokens.filter { $0.value != id }
            state.markRemindersDirty()
            return task.image
        }
        if let image { discardImage(image) }
    }

    func removeFromBasket(_ asset: String) throws {
        try change { state in
            guard !state.deletionInFlight.contains(asset) else { return }
            if state.review[asset] == .pendingDelete { state.review[asset] = nil }
            if state.lastReview?.asset == asset { state.lastReview = nil }
        }
    }

    func beginDeletion(_ assets: [String]) throws {
        try change { state in
            guard state.hasPro() else { throw StorageError.needsPro }
            guard state.deletionInFlight.isEmpty else { throw StorageError.unavailable }
            state.deletionInFlight = assets.filter { state.review[$0] == .pendingDelete }
        }
    }

    func finishDeletion(confirmed: Set<String>, now: Date = .now) throws {
        try change { state in
            let previous = state.deletedAssets.count
            for asset in state.deletionInFlight where confirmed.contains(asset) {
                state.deletedAssets[asset] = state.deletedAssets[asset] ?? now
                state.review[asset] = nil
                if state.lastReview?.asset == asset { state.lastReview = nil }
            }
            state.deletionInFlight = []
            if previous < 100, state.deletedAssets.count >= 100 { state.milestonePending = true }
        }
    }

    func importTemplates(_ items: [TemplateItem]) throws -> Bool {
        _ = try TemplateCode.encode(items)
        return try change { state in
            let existing = Set(state.templates.map(\.id))
            let added = items.filter { !existing.contains($0.id) }
            state.templates.append(contentsOf: added)
            return !added.isEmpty
        }
    }
}
