import SwiftUI

struct TaskForm: View {
    let preview: UIImage?
    let templates: [TemplateItem]
    let autofocus: Bool
    var defaultDue: DueDate? = nil
    let close: () -> Void
    let save: (String, DueDate) async throws -> String?
    var didSave: (() -> Void)?
    @State private var purpose = Launch.testing ? (ProcessInfo.processInfo.environment["STD_TEST_PURPOSE"] ?? "") : ""
    @State private var selectedDue: DueDate?
    @State private var customDate = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmation: String?
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var due: DueDate? { selectedDue ?? defaultDue }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 184)
                            .padding(8)
                            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel(L.t("image.preview"))
                    }
                    Text(L.t("form.purpose")).font(.headline)
                    TextField(L.t("form.placeholder"), text: $purpose)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { focused = false }
                        .onChange(of: purpose) { _, newValue in
                            let oneLine = newValue.components(separatedBy: .newlines).joined(separator: " ")
                            if oneLine != newValue || oneLine.count > 80 { purpose = String(oneLine.prefix(80)) }
                        }
                        .accessibilityIdentifier("form.purpose")
                    if !templates.isEmpty {
                        Menu {
                            ForEach(templates) { item in
                                Button(item.kind.title) {
                                    purpose = item.kind.title
                                    selectedDue = DueDate(day: CivilDay(.now).adding(item.days, in: CivilDay.calendar()), hour: item.hour)
                                    customDate = false
                                    focused = false
                                }
                                .accessibilityIdentifier("form.template." + item.id)
                            }
                        } label: {
                            Label(L.t("template.apply"), systemImage: "doc.on.clipboard")
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("form.template")
                    }
                    Text(L.t("form.date")).font(.headline)
                    if let due {
                        Text(DateText.short(due)).font(.subheadline).foregroundStyle(Theme.muted)
                            .accessibilityIdentifier("form.dueSummary")
                    }
                    if let defaultDue {
                        DatePicker(L.t("form.date"), selection: Binding(
                            get: { (due ?? defaultDue).day.date(in: CivilDay.calendar()) },
                            set: { selectedDue = DueDate.best(on: CivilDay($0)) }
                        ), in: defaultDue.day.date(in: CivilDay.calendar())..., displayedComponents: .date)
                            .environment(\.calendar, CivilDay.calendar())
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("form.photoDate")
                    } else {
                        dateOptions
                    }
                    if defaultDue == nil && customDate {
                        DatePicker(L.t("form.pick"), selection: Binding(
                            get: { due?.day.date(in: CivilDay.calendar()) ?? .now },
                            set: { date in
                                selectedDue = DueDate.best(on: CivilDay(date))
                                customDate = false
                            }), in: CivilDay.calendar().startOfDay(for: .now)..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .accessibilityIdentifier("form.calendar")
                        TextAction(title: L.t("form.useDisplayedDay"), id: "form.calendarConfirm") {
                            selectedDue = DueDate.best(on: due?.day ?? CivilDay(.now))
                            customDate = false
                        }
                    }
                    if let error { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("form.error") }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle(L.t("form.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L.t("action.cancel"))
                    .accessibilityIdentifier("form.cancel")
                    .disabled(saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L.t("action.done")) { focused = false }.accessibilityIdentifier("form.keyboardDone")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let confirmation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(confirmation).accessibilityIdentifier("form.saved")
                        PrimaryButton(title: L.t("action.done"), id: "form.finish", action: didSave ?? close)
                    }
                    .padding(16).background(Theme.background)
                } else {
                    PrimaryButton(title: saving ? L.t("form.saving") : L.t("form.save"), id: "form.save",
                                  disabled: saving || due == nil || purpose.trimmingCharacters(in: .whitespaces).isEmpty,
                                  action: performSave)
                        .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.background)
                }
            }
            .task {
                guard autofocus, !Launch.testing else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled { focused = true }
            }
        }
        .tint(Theme.text)
        .interactiveDismissDisabled(saving)
    }

    private var dateOptions: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            TextAction(title: L.t("form.today"), id: "form.today") { choose(days: 0) }
                .background(due?.day == CivilDay(.now) && !customDate ? Theme.tint : Theme.paper, in: Capsule())
            TextAction(title: L.t("form.tomorrow"), id: "form.tomorrow") { choose(days: 1) }
                .background(due?.day == CivilDay(.now).adding(1, in: CivilDay.calendar()) && !customDate ? Theme.tint : Theme.paper, in: Capsule())
            TextAction(title: L.t("form.pick"), id: "form.pick", systemImage: "calendar") {
                focused = false
                customDate.toggle()
            }
            .background(customDate ? Theme.tint : Theme.paper, in: Capsule())
        }
    }

    private func choose(days: Int) {
        focused = false
        customDate = false
        selectedDue = DueDate.best(on: CivilDay(.now).adding(days, in: CivilDay.calendar()))
    }

    private func performSave() {
        guard let due, !saving else { return }
        focused = false
        saving = true
        error = nil
        Task {
            do {
                let message = try await save(purpose, due)
                if let message { confirmation = message } else { didSave?() }
            } catch {
                self.error = (error as? StorageError)?.message ?? L.t("error.storage")
            }
            saving = false
        }
    }
}
