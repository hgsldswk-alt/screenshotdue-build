import PhotosUI
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var commerce: StoreAccess
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected: PhotosPickerItem?
    @Binding var pickingPhoto: Bool
    @Binding var readingPhoto: Bool
    let open: (AppRoute) -> Void
    let prepare: (Data?) -> Void
    let chooseTemplateFile: () -> Void
    let loadingPhoto: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.ready {
                    HeroCard(due: model.state.sections(at: model.now, calendar: CivilDay.calendar()).today.count,
                             cleared: model.state.progress(at: model.now).cleared)
                    trialNotice
                    notificationBanner
                    let sections = displaySections
                    section(title: L.t("home.today"), tasks: sections.today, today: true)
                    section(title: L.t("home.next"), tasks: sections.next, today: false)
                    actionTiles
                } else if model.startFailed {
                    TextAction(title: L.t("action.retry"), id: "home.retry", systemImage: "arrow.clockwise") {
                        Task { await model.start() }
                    }
                } else if model.message == nil {
                    ProgressView(L.t("action.loading"))
                }
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .photosPicker(isPresented: $pickingPhoto, selection: $selected, matching: .images, preferredItemEncoding: .current)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if model.ready {
                addButton.padding(.horizontal, 18).padding(.vertical, 8).background(Theme.background)
            }
        }
        .onChange(of: selected) { _, item in
            guard let item, !readingPhoto else { return }
            readingPhoto = true
            Task {
                defer { readingPhoto = false; selected = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw StorageError.invalidImage }
                    prepare(data)
                } catch { model.message = L.t("error.image") }
            }
        }
    }

    private var actionTiles: some View {
        let templateLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return VStack(spacing: 8) {
            IconTile(title: L.t("review.open"), id: "home.review", systemImage: "rectangle.stack",
                     color: Theme.ochre, tint: Theme.ochreTint) {
                open(.review)
            }
            templateLayout {
                IconTile(title: L.t("template.open"), id: "home.templateCode", systemImage: "doc.on.clipboard",
                         color: Theme.slate, tint: Theme.slateTint) {
                    open(.template(nil))
                }
                IconTile(title: L.t("template.file"), id: "home.templateFile", systemImage: "folder",
                         color: Theme.forest, tint: Theme.tint, action: chooseTemplateFile)
            }
        }
    }

    @ViewBuilder private var appTitle: some View {
        let title = Text(L.t("app.name")).font(.largeTitle.bold())
        #if DEBUG
        if Launch.testing && model.ready {
            title.contentShape(Rectangle()).onTapGesture(count: 2) { prepare(nil) }
        } else {
            title
        }
        #else
        title
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline).foregroundStyle(Theme.muted)
                appTitle
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.title")
            }
            Spacer(minLength: 2)
            Button {
                open(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.semibold))
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.paper, in: Circle())
            .accessibilityLabel(L.t("settings.title"))
            .accessibilityIdentifier("home.settings")
        }
    }

    @ViewBuilder private var trialNotice: some View {
        if !model.state.trialNoticeSeen, model.hasPro, model.state.entitlement?.purchasedPro != true,
           !Launch.testing || Launch.has("-trial-notice") {
            Paper {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L.t("store.introTitle")).font(.headline)
                    Text(L.t("store.introBody")).font(.subheadline).foregroundStyle(Theme.muted)
                    if let price = commerce.price {
                        Text(L.f("store.price", price)).font(.subheadline).fontWeight(.semibold)
                    } else {
                        Text(L.t("store.priceUnavailable")).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { trialActions }
                        VStack(alignment: .leading) { trialActions }
                    }
                    if let status = commerce.status {
                        Text(status).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
            }
            .task { await commerce.loadProducts() }
        }
    }

    @ViewBuilder private var trialActions: some View {
        if model.state.entitlement?.trialClaimedAt == nil {
            TextAction(title: L.t("store.claim"), id: "home.claimTrial", color: Theme.text) {
                Task { await commerce.buy(trial: true) { await model.refresh(scheduleReminders: true) } }
            }
            .disabled(commerce.working)
        }
        TextAction(title: L.t("action.dismiss"), id: "home.dismissTrial", color: Theme.muted) {
            Task { await model.perform { try $0.change { $0.trialNoticeSeen = true } } }
        }
    }

    @ViewBuilder private var notificationBanner: some View {
        if !Reminders.allowed(model.notifications), model.state.openCount > 0 || model.state.shareNoticeSeen {
            Paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("notification.off")).font(.subheadline).foregroundStyle(Theme.muted)
                    TextAction(title: L.t("notification.enable"), id: "home.enableNotifications", systemImage: "bell") {
                        if model.notifications == .denied, !Launch.testing {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } else {
                            Task { await model.askForNotifications() }
                        }
                    }
                }
            }
        }
    }

    private var displaySections: (today: [ScreenshotTask], next: [ScreenshotTask]) {
        var displayed = model.state
        for (id, task) in model.shownForUndo {
            if let index = displayed.tasks.firstIndex(where: { $0.id == id }) {
                displayed.tasks[index] = task
            }
        }
        return displayed.sections(at: model.now, calendar: CivilDay.calendar())
    }

    private func section(title: String, tasks: [ScreenshotTask], today: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline).foregroundStyle(Theme.muted).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(today ? "home.today" : "home.next")
                StatusPill(title: tasks.count.formatted(),
                           background: today ? Theme.ochreTint : Theme.tint,
                           foreground: today ? Theme.ochre : Theme.forest)
                    .accessibilityHidden(true)
            }
            if tasks.isEmpty {
                Paper {
                    HStack(spacing: 12) {
                        if today && !typeSize.isAccessibilitySize { EmptyIllustration() }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L.t(today ? "home.emptyToday" : "home.emptyNext")).font(.headline)
                            if !today && model.state.tasks.isEmpty {
                                Text(L.t("home.emptyHelp")).font(.subheadline).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, undo: model.shownForUndo[task.id] != nil,
                                open: { open(.task(task.id)) },
                                complete: { Task { await model.complete(task) } },
                                undoAction: { Task { await model.undo(task.id) } })
                    }
                }
            }
        }
    }

    private var addButton: some View {
        let loading = model.canAdd && (readingPhoto || loadingPhoto)
        return PrimaryButton(title: L.t(loading ? "image.loading" : "home.add"),
                             id: "home.add", disabled: loading, systemImage: "plus") {
            if model.canAdd { pickingPhoto = true }
            else { open(.paywall) }
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    let task: ScreenshotTask
    let undo: Bool
    let open: () -> Void
    let complete: () -> Void
    let undoAction: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if undo {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            } else {
                Button(action: complete) {
                    Image(systemName: "circle").font(.title2.weight(.medium))
                        .foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.f("task.accessibleDone", task.purpose))
                .accessibilityIdentifier("home.complete")
            }
            Button(action: open) {
                HStack(spacing: 10) {
                    LocalThumbnail(url: task.image.flatMap { model.store?.imageURL($0, thumbnail: true) })
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.purpose).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(undo ? L.t("task.done") : DateText.short(task.due, now: model.now))
                            .font(.subheadline)
                            .foregroundStyle(task.due.day < CivilDay(model.now) && !undo ? Theme.danger : Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if !undo { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.task")
            if undo {
                TextAction(title: L.t("action.undo"), id: "home.undo", action: undoAction)
            }
        }
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line).allowsHitTesting(false) }
    }
}

struct LocalThumbnail: View {
    let url: URL?
    @State private var image: UIImage?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if !typeSize.isAccessibilitySize {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.tint)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(Theme.muted) }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            .task(id: url) {
                image = nil
                guard let url else { return }
                let thumbnail = await Task.detached(priority: .utility) { PhotoData.image(at: url, edge: 144) }.value
                if !Task.isCancelled { image = thumbnail }
            }
        }
    }
}
