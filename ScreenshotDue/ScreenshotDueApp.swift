import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum AppRoute: Hashable {
    case task(UUID), settings, review, basket, history, paywall, progress, milestone, template(String?), widgets, privacy
}

enum NotificationRoute: Equatable {
    case task(UUID), today
}

final class NotificationRouter: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var route: NotificationRoute?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let task = (info["task"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run { route = task.map(NotificationRoute.task) ?? .today }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct ScreenshotDueApp: App {
    @UIApplicationDelegateAdaptor(NotificationRouter.self) private var router
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(router: router)
                .environmentObject(model)
                .environmentObject(model.commerce)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var commerce: StoreAccess
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @ObservedObject var router: NotificationRouter
    @State private var path: [AppRoute] = []
    @State private var draft: Draft?
    @State private var reviewRequested = false
    @State private var claimingReview = false
    @State private var incomingFile: String?
    @State private var pickingTemplateFile = false
    @State private var loadingTemplateFile = false
    @State private var loadingPhoto = false
    @State private var pickingPhoto = false
    @State private var readingPhoto = false
    @State private var firstRouting = true

    private struct Draft: Identifiable {
        let id = UUID()
        let photo: PreparedPhoto
        let preview: UIImage?
        let defaultDue: DueDate?
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(pickingPhoto: $pickingPhoto, readingPhoto: $readingPhoto, open: push, prepare: prepare,
                     chooseTemplateFile: { pickingTemplateFile = true }, loadingPhoto: loadingPhoto)
                .navigationDestination(for: AppRoute.self) { route in
                    screen(route).toolbar(.visible, for: .navigationBar)
                }
        }
        .tint(Theme.text)
        .sheet(item: $draft) { draft in
            TaskForm(preview: draft.preview, templates: model.state.templates, autofocus: true, defaultDue: draft.defaultDue,
                     close: { self.draft = nil }, save: { purpose, date in
                        _ = try await model.save(photo: draft.photo, token: draft.id, purpose: purpose, due: date)
                        return nil
                     }, didSave: { self.draft = nil })
        }
        .fileImporter(isPresented: Binding(get: { pickingTemplateFile && templateFileFixture == nil },
                                           set: { pickingTemplateFile = $0 }),
                      allowedContentTypes: [.screenshotDueTemplate, .plainText], onCompletion: importTemplateFile)
        .confirmationDialog(L.t("template.file"), isPresented: Binding(
            get: { pickingTemplateFile && templateFileFixture != nil }, set: { pickingTemplateFile = $0 }
        )) {
            Button("Sample.stdtemplate", action: selectTemplateFileFixture)
                .accessibilityIdentifier("test.templateFile")
        }
        .alert(L.t("error.title"), isPresented: Binding(get: { model.message != nil },
                                                        set: { if !$0 { model.message = nil } })) {
            Button(L.t("action.ok"), role: .cancel) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .overlay(alignment: .bottom) {
            if reviewRequested && Launch.testing {
                Text(L.t("review.requested")).padding().background(Theme.tint, in: Capsule())
                    .accessibilityIdentifier("rating.requested")
            }
        }
        .task {
            if Launch.testing, let code = ProcessInfo.processInfo.environment["STD_TEST_TEMPLATE"] {
                UIPasteboard.general.string = code
            }
            await model.start()
            handleInitialRoute()
        }
        .onChange(of: model.ready) { _, ready in if ready { handleInitialRoute() } }
        .onChange(of: router.route) { _, _ in serviceNotification() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await model.becameActive() } }
        }
        .onOpenURL(perform: openURL)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if phase == .active { Task { await model.clockChanged(force: true) } }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !Task.isCancelled, phase == .active { await model.clockChanged() }
            }
        }
        .task(id: reviewCandidateDay) { [day = reviewCandidateDay] in
            guard let day else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, reviewHomeIsIdle, !claimingReview, day == CivilDay(.now) else { return }
            claimingReview = true
            defer { claimingReview = false }
            await model.requestReview(version: version, on: day, ifIdle: { reviewHomeIsIdle }) {
                if Launch.testing { reviewRequested = true }
                else { requestReview() }
            }
        }
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private var reviewCandidateDay: CivilDay? {
        let day = CivilDay(model.now)
        return reviewHomeIsIdle && model.state.isReviewEligible(version: version, on: day) ? day : nil
    }

    private var reviewHomeIsIdle: Bool {
        model.ready && !firstRouting && path.isEmpty && draft == nil && phase == .active &&
        UIApplication.shared.applicationState == .active && model.message == nil && model.shownForUndo.isEmpty &&
        !model.requestingNotificationPermission && !commerce.working && !loadingPhoto && !pickingPhoto &&
        !readingPhoto && !pickingTemplateFile && !loadingTemplateFile && router.route == nil && !reviewRequested
    }

    @ViewBuilder
    private func screen(_ route: AppRoute) -> some View {
        switch route {
        case .task(let id): TaskDetail(id: id, open: push)
        case .settings: SettingsView(open: push)
        case .review: OldReviewView(open: push)
        case .basket: DeletionBasket(open: push)
        case .history: HistoryView(open: push)
        case .paywall: PaywallView()
        case .progress: ProgressShareView(milestone: false, open: push)
        case .milestone: ProgressShareView(milestone: true, open: push)
        case .template(let code):
            TemplateImportView(initial: code, chooseFile: { pickingTemplateFile = true }).id(code)
        case .widgets: WidgetGuideView()
        case .privacy: PrivacyView()
        }
    }

    private func push(_ route: AppRoute) { path.append(route) }

    private func handleInitialRoute() {
        guard model.ready, firstRouting else { return }
        firstRouting = false
        if let incomingFile { path = [.template(incomingFile)] }
        if Launch.testing {
            if Launch.has("-paywall") { path = [.paywall] }
            if Launch.has("-notification-task") { router.route = .task(DemoData.notificationTask) }
        }
        serviceNotification()
    }

    private func serviceNotification() {
        guard model.ready, let route = router.route else { return }
        draft = nil
        switch route {
        case .today:
            path = []
            router.route = nil
        case .task(let id):
            Task {
                await model.refresh()
                guard router.route == route else { return }
                path = model.state.tasks.contains { $0.id == id } ? [.task(id)] : []
                router.route = nil
            }
        }
    }

    private func prepare(_ data: Data?) {
        guard !loadingPhoto else { return }
        #if DEBUG
        guard data != nil || Launch.testing else { return }
        #else
        guard data != nil else { return }
        #endif
        loadingPhoto = true
        Task {
            defer { loadingPhoto = false }
            do {
                let now = Date.now
                let defaultDue = data != nil || Launch.testing && Launch.has("-app-photo-import")
                    ? DueDate.best(on: CivilDay(now), now: now) : nil
                draft = try await Task.detached(priority: .userInitiated) {
                    let photo: PreparedPhoto
                    if let data {
                        photo = try PreparedPhoto(data: data)
                    } else {
                        #if DEBUG
                        photo = try DemoData.photo()
                        #else
                        throw StorageError.invalidImage
                        #endif
                    }
                    return Draft(photo: photo, preview: PhotoData.preview(photo.thumbnail, edge: 400), defaultDue: defaultDue)
                }.value
            } catch { model.message = L.t("error.image") }
        }
    }

    private func openURL(_ url: URL) {
        if url.scheme == "screenshotdue", url.host == "today" {
            router.route = .today
        } else if url.scheme == "screenshotdue", url.host == "task",
                  let id = UUID(uuidString: url.lastPathComponent) {
            router.route = .task(id)
        } else if url.isFileURL && url.pathExtension.lowercased() == "stdtemplate" {
            importTemplateFile(.success(url))
        }
    }

    private func importTemplateFile(_ result: Result<URL, Error>) {
        guard !loadingTemplateFile else { return }
        loadingTemplateFile = true
        Task {
            defer { loadingTemplateFile = false }
            do {
                let code = try await readTemplateFile(result.get())
                if !model.ready { incomingFile = code }
                else if case .template? = path.last { path[path.count - 1] = .template(code) }
                else { push(.template(code)) }
            } catch {
                if (error as? CocoaError)?.code != .userCancelled { model.message = L.t("error.template") }
            }
        }
    }

    private var templateFileFixture: String? {
        guard Launch.testing, Launch.has("-template-file-fixture") else { return nil }
        return ProcessInfo.processInfo.environment["STD_TEST_TEMPLATE"]
    }

    private func selectTemplateFileFixture() {
        guard let templateFileFixture else { return }
        let url = URL.temporaryDirectory.appendingPathComponent("ScreenshotDueTest.stdtemplate")
        importTemplateFile(Result {
            try Data(templateFileFixture.utf8).write(to: url, options: .atomic)
            return url
        })
    }
}
