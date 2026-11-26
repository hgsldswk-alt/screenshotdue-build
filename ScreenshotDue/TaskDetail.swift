import PhotosUI
import SwiftUI
import UIKit

struct TaskDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?
    @State private var loadingImage = true
    @State private var editor = ""
    @State private var editing = false
    @State private var choosingDay = false
    @State private var choosingTime = false
    @State private var confirmRemove = false
    @State private var replacement: PhotosPickerItem?
    @FocusState private var focus: Bool
    let id: UUID
    let open: (AppRoute) -> Void

    private var current: ScreenshotTask? { model.state.tasks.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let task = current {
                VStack(alignment: .leading, spacing: 17) {
                    imageArea(task)
                    purposeArea(task)
                    Paper { reminderArea(task) }
                    if task.completedAt == nil {
                        PrimaryButton(title: L.t("task.markDone"), id: "detail.done") { Task { await model.complete(task) } }
                    } else {
                        Label(L.t("task.done"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.text).accessibilityIdentifier("detail.completed")
                        TextAction(title: L.t("action.undo"), id: "detail.undo") { Task { await model.undo(id) } }
                        if task.image != nil {
                            TextAction(title: L.t("task.deleteCopy"), id: "detail.removeCopy", color: Theme.danger) { confirmRemove = true }
                        }
                    }
                }
                .padding(18)
                .task(id: task.image) { await loadImage(task.image) }
            } else {
                ContentUnavailableView(L.t("error.missing"), systemImage: "photo")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("task.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L.t("task.deleteCopy"), isPresented: $confirmRemove) {
            Button(L.t("task.deleteCopy"), role: .destructive) { Task { await model.perform { [id] in try $0.removeCopy(id) } } }
            Button(L.t("action.cancel"), role: .cancel) {}
        } message: { Text(L.t("task.deleteCopyHelp")) }
        .onChange(of: replacement) { _, item in
            guard let item else { return }
            Task { await replace(item); replacement = nil }
        }
    }

    @ViewBuilder private func imageArea(_ task: ScreenshotTask) -> some View {
        if let image {
            ZoomImage(image: image)
                .frame(height: min(440, max(230, 335 * image.size.height / max(1, image.size.width))))
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(L.t("image.original"))
                .accessibilityIdentifier("detail.original")
        } else if loadingImage {
            ProgressView(L.t("image.loading")).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Paper {
                VStack(alignment: .leading, spacing: 5) {
                    Label(L.t("image.missing"), systemImage: "photo")
                    PhotosPicker(selection: $replacement, matching: .images, preferredItemEncoding: .current) {
                        Text(L.t("image.replace")).fontWeight(.semibold)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("detail.replace")
                }
            }
        }
    }

    @ViewBuilder private func purposeArea(_ task: ScreenshotTask) -> some View {
        if editing {
            TextField(L.t("form.purpose"), text: $editor)
                .textFieldStyle(.roundedBorder).focused($focus)
                .submitLabel(.done)
                .onSubmit { focus = false }
                .accessibilityIdentifier("detail.purposeField")
                .onChange(of: editor) { _, value in
                    if value.count > 80 { editor = String(value.prefix(80)) }
                }
            HStack {
                TextAction(title: L.t("action.save"), id: "detail.savePurpose") {
                    Task {
                        do {
                            let purpose = try ScreenshotTask.purpose(editor)
                            try await model.apply({ [id] in try $0.updateTask(id) { task, _ in task.purpose = purpose } }, reminders: true)
                            editing = false
                            focus = false
                        } catch { model.message = (error as? StorageError)?.message ?? L.t("error.storage") }
                    }
                }
                TextAction(title: L.t("action.cancel"), id: "detail.cancelPurpose") { editing = false; focus = false }
            }
        } else {
            Text(task.purpose).font(.title2.bold()).accessibilityIdentifier("detail.purpose")
            TextAction(title: L.t("action.edit"), id: "detail.editPurpose", systemImage: "pencil") {
                editor = task.purpose
                editing = true
                focus = true
            }
        }
    }

    private func reminderArea(_ task: ScreenshotTask) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L.t("task.reminders")).font(.headline)
            Menu {
                Button(L.t("form.today")) { setDay(CivilDay(.now)) }
                Button(L.t("form.tomorrow")) { setDay(CivilDay(.now).adding(1, in: CivilDay.calendar())) }
                Button(L.t("form.pick")) { choosingDay.toggle(); choosingTime = false }
            } label: {
                Label(DateText.short(task.due, now: model.now), systemImage: "calendar")
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("detail.date")
            if choosingDay {
                DatePicker(L.t("form.pick"), selection: Binding(
                    get: { task.due.day.date(in: CivilDay.calendar()) },
                    set: { setDay(CivilDay($0)); choosingDay = false }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("detail.calendar")
            }
            TextAction(title: L.f("task.time", DateText.clock(task.due)), id: "detail.time", systemImage: "clock") {
                choosingTime.toggle()
                choosingDay = false
            }
            if choosingTime {
                DatePicker(L.t("task.reminderTime"), selection: Binding(
                    get: { task.due.date(in: CivilDay.calendar()) },
                    set: { newTime in
                        let parts = CivilDay.calendar().dateComponents([.hour, .minute], from: newTime)
                        guard let hour = parts.hour, let minute = parts.minute else { return }
                        updateDate(DueDate(day: task.due.day, hour: hour, minute: minute))
                    }), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("detail.timePicker")
            }
            if !model.hasPro && task.repeatRule == .never {
                TextAction(title: L.t("task.repeatPro"), id: "detail.repeat", systemImage: "repeat") { open(.paywall) }
            } else {
                Menu {
                    ForEach(RepeatRule.allCases) { rule in
                        Button(rule.title) {
                            if rule != .never && !model.hasPro { open(.paywall); return }
                            Task {
                                await model.perform({ [id] store in
                                    try store.updateTask(id) { task, premium in
                                        guard premium || rule == .never else { throw StorageError.needsPro }
                                        task.repeatRule = rule
                                    }
                                }, reminders: true)
                            }
                        }
                    }
                } label: {
                    Label(L.f("task.repeat", task.repeatRule.title), systemImage: "repeat")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("detail.repeat")
                if !model.hasPro {
                    Text(L.t("task.repeatPaused")).font(.footnote).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func setDay(_ day: CivilDay) { updateDate(DueDate.best(on: day)) }

    private func updateDate(_ due: DueDate) {
        Task { await model.perform({ [id] in try $0.updateTask(id) { task, _ in task.due = due } }, reminders: true) }
    }

    private func replace(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw StorageError.invalidImage }
            try await model.apply { [id] in try $0.replaceImage(id, photo: PreparedPhoto(data: data)) }
        } catch { model.message = (error as? StorageError)?.message ?? L.t("error.image") }
    }

    private func loadImage(_ key: UUID?) async {
        image = nil
        loadingImage = true
        guard let key, let url = model.store?.imageURL(key, thumbnail: false) else { loadingImage = false; return }
        let loaded = await Task.detached(priority: .userInitiated) { PhotoData.image(at: url, edge: 8192) }.value
        guard !Task.isCancelled else { return }
        image = loaded
        loadingImage = false
    }
}

private struct ZoomImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        let view = context.coordinator.image
        view.image = image
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        scroll.isAccessibilityElement = true
        scroll.accessibilityTraits = .image
        scroll.accessibilityLabel = L.t("image.original")
        scroll.accessibilityIdentifier = "detail.original"
        scroll.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L.t("image.zoomIn")) { [weak scroll] _ in
                guard let scroll else { return false }
                scroll.setZoomScale(min(scroll.maximumZoomScale, scroll.zoomScale + 1), animated: true)
                return true
            },
            UIAccessibilityCustomAction(name: L.t("image.zoomOut")) { [weak scroll] _ in
                guard let scroll else { return false }
                scroll.setZoomScale(max(scroll.minimumZoomScale, scroll.zoomScale - 1), animated: true)
                return true
            }
        ]
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.image.image !== image {
            context.coordinator.image.image = image
            uiView.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let image = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
        @objc func doubleTap(_ sender: UITapGestureRecognizer) {
            guard let scroll = sender.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = sender.location(in: image)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
