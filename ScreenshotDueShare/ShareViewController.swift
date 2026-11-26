import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        let screen = ExtensionScreen(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        let host = UIHostingController(rootView: screen)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct ExtensionScreen: View {
    let providers: [NSItemProvider]
    let close: () -> Void
    @State private var input: Input?
    @State private var error: String?
    @State private var token = UUID()
    @State private var finished = false

    private struct Input {
        let store: TaskStore
        let photo: PreparedPhoto
        let preview: UIImage?
        let templates: [TemplateItem]
    }

    var body: some View {
        Group {
            if let input {
                TaskForm(preview: input.preview, templates: input.templates, autofocus: true,
                         close: finish, save: { purpose, due in
                    _ = try await ImportFlow.save(store: input.store, photo: input.photo,
                                                  token: token, purpose: purpose, due: due, waitForReminders: true)
                    guard !Reminders.allowed(await Reminders.status()) else { return nil }
                    let showNotice = (try? await Task.detached {
                        try input.store.change { state in
                            guard !state.shareNoticeSeen else { return false }
                            state.shareNoticeSeen = true
                            return true
                        }
                    }.value) ?? true
                    guard showNotice else { return nil }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        finish()
                    }
                    return L.t("notification.savedWithoutPermission")
                }, didSave: finish)
            } else {
                VStack(spacing: 16) {
                    if let error {
                        Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("share.error")
                        TextAction(title: L.t("action.retry"), id: "share.retry") { Task { await load() } }
                    } else {
                        ProgressView(L.t("image.loading"))
                    }
                    TextAction(title: L.t("action.cancel"), id: "share.cancel", action: finish)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            }
        }
        .task { await load() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        close()
    }

    private func load() async {
        error = nil
        do {
            guard providers.count == 1, let provider = providers.first else {
                throw providers.isEmpty ? StorageError.invalidImage : StorageError.multipleImages
            }
            let data = try await read(provider)
            input = try await Task.detached(priority: .userInitiated) {
                let store = try TaskStore.shared()
                let photo = try PreparedPhoto(data: data)
                let state = try store.bootstrap()
                return Input(store: store, photo: photo, preview: PhotoData.preview(photo.thumbnail, edge: 400),
                             templates: state.templates)
            }.value
        } catch {
            self.error = (error as? StorageError)?.message ?? L.t("error.image")
        }
    }

    private func read(_ provider: NSItemProvider) async throws -> Data {
        let imageType = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true && $0 != UTType.image.identifier
        } ?? UTType.image.identifier
        do {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, error in
                    do {
                        guard let url else { throw error ?? StorageError.missing }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard (1...(64 * 1024 * 1024)).contains(size) else { throw StorageError.invalidImage }
                        continuation.resume(returning: try Data(contentsOf: url, options: .mappedIfSafe))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch StorageError.invalidImage {
            throw StorageError.invalidImage
        } catch {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? StorageError.invalidImage) }
                }
            }
        }
    }
}
