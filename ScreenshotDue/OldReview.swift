import Photos
import SwiftUI
import UIKit

enum ScreenshotLibrary {
    static func access() -> PHAuthorizationStatus {
        Launch.testing ? (Launch.has("-limited") ? .limited : .authorized) : PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func assets() -> [String] {
        if Launch.testing { return DemoData.oldAssets }
        let query = PHFetchOptions()
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetched = PHAsset.fetchAssets(with: .image, options: query)
        var ids: [String] = []
        fetched.enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) { ids.append(asset.localIdentifier) }
        }
        return ids
    }

    static func localData(_ id: String) -> Data? {
        if Launch.testing {
            if Launch.has("-cloud-photo") && id == DemoData.oldAssets.first { return nil }
            return try? DemoData.photo((DemoData.oldAssets.firstIndex(of: id) ?? 0) + 30).original
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        var output: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            if info?[PHImageCancelledKey] as? Bool != true { output = data }
        }
        return output
    }

    static func stillVisible(_ ids: [String]) -> Set<String> {
        if Launch.testing { return Set(ids) }
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
        }
        return found
    }

    static func delete(_ ids: [String]) async throws -> Set<String> {
        if Launch.testing { return Set(ids) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var submitted = Set<String>()
        assets.enumerateObjects { asset, _, _ in submitted.insert(asset.localIdentifier) }
        guard !submitted.isEmpty else { return [] }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        return submitted
    }
}

struct OldReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var decisionHeight = 62.0
    @State private var auth = PHAuthorizationStatus.notDetermined
    @State private var assets: [String] = []
    @State private var skipped: Set<String> = []
    @State private var image: UIImage?
    @State private var displayed: String?
    @State private var loading = true
    @State private var committing = false
    @State private var issue: String?
    let open: (AppRoute) -> Void

    private var current: String? { assets.first { model.state.review[$0] == nil && !skipped.contains($0) } }
    private var reviewed: Int { assets.filter { model.state.review[$0] != nil }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProgressView(value: Double(reviewed), total: Double(max(1, assets.count)))
                    .tint(Theme.accent)
                    .accessibilityLabel(L.t("review.progress"))
                Text(L.f("review.counter", min(reviewed + skipped.count + (current == nil ? 0 : 1), assets.count), assets.count))
                    .font(.subheadline).foregroundStyle(Theme.muted).accessibilityIdentifier("review.counter")
                if !model.hasPro {
                    Paper {
                        VStack(alignment: .leading) {
                            Text(L.t("review.locked"))
                            TextAction(title: L.t("store.open"), id: "review.unlock") { open(.paywall) }
                        }
                    }
                }
                permission
                if auth == .authorized || auth == .limited {
                    picture
                    if let current, displayed == current, model.hasPro {
                        if image != nil { decisions(current) }
                        else {
                            Text(L.t("review.localOnly")).foregroundStyle(Theme.muted)
                                .accessibilityIdentifier("review.localOnly")
                            TextAction(title: L.t("review.skip"), id: "review.skip") { skipped.insert(current) }
                        }
                    }
                }
                if let issue { Text(issue).foregroundStyle(Theme.danger).accessibilityIdentifier("review.error") }
                if let last = model.state.lastReview, model.hasPro || last.choice == .pendingDelete {
                    TextAction(title: L.t("review.undo"), id: "review.undo", systemImage: "arrow.uturn.backward") {
                        guard !committing else { return }
                        issue = nil
                        Task { await model.perform({ try $0.undoReview() }, reminders: true) }
                    }
                    .disabled(committing)
                }
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("review.title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !model.state.basket.isEmpty {
                PrimaryButton(title: L.f("review.basketCount", model.state.basket.count), id: "review.basket") {
                    open(.basket)
                }
                .padding(.horizontal, 18).padding(.vertical, 8).background(Theme.background)
            }
        }
        .task { await reload() }
        .task(id: current) { await loadThumbnail(current) }
        .onChange(of: phase) { _, next in if next == .active { Task { await reload() } } }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotAccessChanged)) { _ in
            Task { await reload() }
        }
    }

    @ViewBuilder private var permission: some View {
        switch auth {
        case .notDetermined:
            if model.hasPro {
                Text(L.t("review.permission"))
                PrimaryButton(title: L.t("review.allow"), id: "review.allow") {
                    Task {
                        if !Launch.testing { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                        await reload()
                    }
                }
            }
        case .denied, .restricted:
            Text(L.t("review.denied"))
            TextAction(title: L.t("action.settings"), id: "review.settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .limited:
            Text(L.t("review.limited")).font(.subheadline).foregroundStyle(Theme.muted)
            TextAction(title: L.t("review.manage"), id: "review.manage") {
                guard !Launch.testing else { return }
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                guard var presenter = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
                while let next = presenter.presentedViewController { presenter = next }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { _ in
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .screenshotAccessChanged, object: nil) }
                }
            }
        case .authorized: EmptyView()
        @unknown default: EmptyView()
        }
    }

    @ViewBuilder private var picture: some View {
        if let current {
            if displayed == current, let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 390)
                    .padding(8).background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(L.t("image.original"))
                    .accessibilityIdentifier("review.image")
            } else if displayed != current || loading {
                ProgressView(L.t("image.loading")).frame(maxWidth: .infinity, minHeight: 160)
            }
        } else {
            Paper { Text(L.t("review.finished")).accessibilityIdentifier("review.finished") }
        }
    }

    private func decisions(_ asset: String) -> some View {
        HStack(spacing: 8) {
            decisionButton("review.makeTask", icon: "checkmark.circle", ink: .white, fill: Theme.forestFill) {
                resolve(asset, choice: .madeTask)
            }
            decisionButton("review.keep", icon: "tray", ink: Theme.text, fill: Theme.card) {
                resolve(asset, choice: .keep)
            }
            decisionButton("review.markDelete", icon: "trash", ink: Theme.danger, fill: Theme.dangerTint) {
                resolve(asset, choice: .pendingDelete)
            }
        }
        .disabled(committing)
        .opacity(committing ? 0.55 : 1)
    }

    private func decisionButton(_ key: String, icon: String, ink: Color, fill: Color,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(L.t(key)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 4)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: decisionHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line.opacity(0.65)).allowsHitTesting(false) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(key)
    }

    private func reload() async {
        auth = ScreenshotLibrary.access()
        guard auth == .authorized || auth == .limited else { return }
        let found = await Task.detached(priority: .utility) { ScreenshotLibrary.assets() }.value
        assets = found.filter { model.state.deletedAssets[$0] == nil }
    }

    private func loadThumbnail(_ id: String?) async {
        displayed = nil
        image = nil
        loading = true
        guard let id else { loading = false; return }
        let thumbnail = await Task.detached(priority: .userInitiated) {
            ScreenshotLibrary.localData(id).flatMap { PhotoData.preview($0, edge: 950) }
        }.value
        guard !Task.isCancelled else { return }
        image = thumbnail
        displayed = id
        loading = false
    }

    private func resolve(_ asset: String, choice: ReviewChoice) {
        guard !committing else { return }
        issue = nil
        committing = true
        Task {
            defer { committing = false }
            do {
                if choice == .madeTask {
                    let photo = try await Task.detached(priority: .userInitiated) {
                        guard let data = ScreenshotLibrary.localData(asset) else { throw StorageError.invalidImage }
                        return try PreparedPhoto(data: data)
                    }.value
                    let due = DueDate(day: CivilDay(.now).adding(1, in: CivilDay.calendar()))
                    _ = try await model.save(photo: photo, token: UUID(), purpose: L.t("review.defaultPurpose"), due: due, asset: asset)
                } else {
                    try await model.apply { try $0.review(asset, choice: choice) }
                }
            } catch {
                issue = (error as? StorageError)?.message ?? L.t("error.storage")
            }
        }
    }
}

private extension Notification.Name {
    static let screenshotAccessChanged = Self("screenshotAccessChanged")
}

struct DeletionBasket: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var deleting = false
    @State private var showFixtureConfirm = false
    @State private var result: Int?
    @State private var milestoneOffered = false
    @State private var issue: String?
    @State private var visible: Set<String> = []
    let open: (AppRoute) -> Void

    private var available: [String] { model.state.basket.filter(visible.contains) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 15) {
                Text(L.t("basket.help")).foregroundStyle(Theme.muted)
                if let result {
                    Paper {
                        VStack(alignment: .leading) {
                            Text(L.f("basket.result", result)).font(.headline).accessibilityIdentifier("basket.result")
                            TextAction(title: L.t("share.progress"), id: "basket.share") { open(.progress) }
                            if milestoneOffered {
                                TextAction(title: L.t("milestone.open"), id: "basket.milestone") { open(.milestone) }
                            }
                        }
                    }
                }
                ForEach(Array(model.state.basket.enumerated()), id: \.element) { index, id in
                    Paper {
                        HStack {
                            BasketThumbnail(id: id)
                            Text(L.f("basket.item", index + 1))
                            Spacer(minLength: 4)
                            TextAction(title: L.t("basket.remove"), id: "basket.remove") {
                                Task { await model.perform { try $0.removeFromBasket(id) } }
                            }
                            .disabled(deleting || model.state.deletionInFlight.contains(id))
                        }
                    }
                }
                if model.state.basket.isEmpty && result == nil { Text(L.t("basket.empty")) }
                if available.count < model.state.basket.count {
                    Text(L.t("basket.unavailable")).foregroundStyle(Theme.muted)
                }
                if let issue { Text(issue).foregroundStyle(Theme.danger).accessibilityIdentifier("basket.error") }
                if model.hasPro {
                    PrimaryButton(title: L.f("basket.delete", available.count), id: "basket.delete",
                                  disabled: available.isEmpty || deleting || !model.state.deletionInFlight.isEmpty) {
                        if Launch.testing { showFixtureConfirm = true }
                        else { Task { await delete() } }
                    }
                    if !model.state.deletionInFlight.isEmpty && !deleting {
                        Text(L.t("basket.interrupted")).font(.footnote).foregroundStyle(Theme.muted)
                        TextAction(title: L.t("basket.release"), id: "basket.release") {
                            Task { await model.perform { try $0.finishDeletion(confirmed: []) } }
                        }
                    }
                } else {
                    Text(L.t("review.locked"))
                    TextAction(title: L.t("store.open"), id: "basket.unlock") { open(.paywall) }
                }
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("basket.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.state.basket) {
            let ids = model.state.basket
            visible = await Task.detached(priority: .utility) { ScreenshotLibrary.stillVisible(ids) }.value
        }
        .alert(L.t("basket.confirm"), isPresented: $showFixtureConfirm) {
            Button(L.t("action.cancel"), role: .cancel) {}
            Button(L.t("action.delete"), role: .destructive) { Task { await delete() } }
        }
    }

    private func delete() async {
        guard !deleting else { return }
        deleting = true
        issue = nil
        defer { deleting = false }
        let ids = available
        do {
            try await model.apply { try $0.beginDeletion(ids) }
        } catch {
            issue = (error as? StorageError)?.message ?? L.t("error.storage")
            return
        }
        let outcome: Set<String>
        do {
            outcome = try await ScreenshotLibrary.delete(ids)
        } catch {
            if (error as NSError).code == NSUserCancelledError {
                await model.perform { try $0.finishDeletion(confirmed: []) }
                return
            }
            let gone: Set<String> = await Task.detached(priority: .utility) {
                guard ScreenshotLibrary.access() == .authorized else { return [] }
                return Set(ids).subtracting(ScreenshotLibrary.stillVisible(ids))
            }.value
            await model.perform { try $0.finishDeletion(confirmed: gone) }
            if !gone.isEmpty { await showResult(gone.count) }
            issue = L.t("basket.failed")
            return
        }
        do {
            try await model.apply { try $0.finishDeletion(confirmed: outcome) }
            await showResult(outcome.count)
            if outcome.count < ids.count { issue = L.t("basket.failed") }
        } catch {
            issue = L.t("error.storage")
        }
    }

    private func showResult(_ count: Int) async {
        result = count
        milestoneOffered = false
        guard model.state.milestonePending else { return }
        do {
            milestoneOffered = try await model.apply { store in
                try store.change { state in
                    guard state.milestonePending else { return false }
                    state.milestonePending = false
                    return true
                }
            }
        } catch {
            issue = L.t("error.storage")
        }
    }
}

private struct BasketThumbnail: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(Theme.muted) }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
        .task {
            image = await Task.detached(priority: .utility) { [id] in
                ScreenshotLibrary.localData(id).flatMap { PhotoData.preview($0, edge: 110) }
            }.value
        }
    }
}
