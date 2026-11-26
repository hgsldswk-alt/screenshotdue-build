import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ProgressShareView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var series = false
    @State private var share: ShareRequest?
    @State private var requested = false
    @State private var copied = false
    @State private var rendering = false
    let milestone: Bool
    let open: (AppRoute) -> Void

    private var counts: ProgressCounts { model.state.progress(at: model.now) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Paper {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.t("app.name")).font(.subheadline).foregroundStyle(Theme.muted)
                        Text(L.t(milestone ? "milestone.title" : "share.week")).font(.title2.bold())
                        stat(milestone ? 100 : counts.cleared, key: "share.cleared")
                        if !milestone { stat(counts.done, key: "share.done") }
                        HStack {
                            if let qr = ShareCard.qr(AppLinks.download) {
                                Image(uiImage: UIImage(cgImage: qr)).interpolation(.none).resizable()
                                    .frame(width: 66, height: 66).padding(8).background(.white)
                                    .accessibilityLabel(L.t("share.qr"))
                                    .accessibilityIdentifier("share.qr")
                            }
                            VStack(alignment: .leading) {
                                Text(L.t(AppLinks.storeID == nil ? "share.qrPlaceholder" : "share.qr"))
                                Text("#ScreenshotToDo").fontWeight(.semibold)
                            }.font(.subheadline)
                        }
                        if series { Text(L.t("share.series")).font(.footnote).foregroundStyle(Theme.muted) }
                    }
                    .padding(7)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("share.preview")
                Toggle(L.t("share.includeSeries"), isOn: $series).accessibilityIdentifier("share.series")
                PrimaryButton(title: L.t("share.image"), id: "share.image", disabled: rendering, action: makeCard)
                TextAction(title: L.t("template.copy"), id: "share.copyTemplate", systemImage: "doc.on.doc") {
                    if let code = try? TemplateCode.encode() {
                        UIPasteboard.general.string = code
                        copied = true
                    }
                }
                TextAction(title: L.t("template.shareFile"), id: "share.templateFile", systemImage: "doc") { makeFile() }
                if copied { Text(L.t("template.copied")).accessibilityIdentifier("share.copied") }
                if requested { Text(L.t("share.requested")).accessibilityIdentifier("share.requested") }
                CleanerLink()
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t(milestone ? "milestone.title" : "share.progress"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { request in SystemShare(items: request.items) }
        .task {
            if milestone && model.state.milestonePending {
                await model.perform { try $0.change { $0.milestonePending = false } }
            }
        }
    }

    private func stat(_ value: Int, key: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font((typeSize.isAccessibilitySize ? Font.title : .largeTitle).bold()).monospacedDigit()
            Text(L.t(key)).font(.headline)
        }
    }

    private func makeCard() {
        rendering = true
        let content = ShareCardContent(counts: counts, milestone: milestone, appName: L.t("app.name"),
                                       download: AppLinks.download, isPlaceholder: AppLinks.storeID == nil, series: series)
        Task {
            let card = await Task.detached(priority: .userInitiated) { ShareCard.render(content) }.value
            rendering = false
            present([card])
        }
    }

    private func makeFile() {
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent("Screenshot-To-Do.stdtemplate")
                    try Data(TemplateCode.encode().utf8).write(to: url, options: .atomic)
                    return url
                }.value
                if Launch.testing { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                present([url])
            } catch { model.message = L.t("error.template") }
        }
    }

    private func present(_ items: [Any]) {
        if Launch.testing { requested = true }
        else { share = ShareRequest(items: items) }
    }
}

private struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct SystemShare: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            for case let url as URL in items where url.pathExtension == "stdtemplate" {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension UTType {
    static let screenshotDueTemplate = UTType(exportedAs: "com.hgsldswk.screenshotdue.template")
}

func readTemplateFile(_ url: URL) async throws -> String {
    try await Task.detached(priority: .utility) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: TemplateCode.maxBytes + 1) ?? Data()
        guard data.count <= TemplateCode.maxBytes, let code = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidTemplate
        }
        _ = try TemplateCode.decode(code)
        return code
    }.value
}

struct TemplateImportView: View {
    @EnvironmentObject private var model: AppModel
    @State private var code: String
    @State private var message: String?
    @State private var importing = false
    let chooseFile: () -> Void

    init(initial: String?, chooseFile: @escaping () -> Void) {
        _code = State(initialValue: initial ?? "")
        self.chooseFile = chooseFile
    }

    private var parsed: [TemplateItem]? { try? TemplateCode.decode(code) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("template.help")).foregroundStyle(Theme.muted)
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { code = value; message = nil }
                }.accessibilityIdentifier("template.paste")
                TextField(L.t("template.placeholder"), text: $code, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("template.code")
                TextAction(title: L.t("template.file"), id: "template.file", systemImage: "folder", action: chooseFile)
                    .disabled(importing)
                if let parsed {
                    Paper {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(parsed) { item in
                                Text(L.f("template.summary", item.kind.title, item.days, item.hour))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("template.preview")
                } else if !code.isEmpty {
                    Text(L.t("error.template")).foregroundStyle(Theme.danger)
                }
                if let message { Text(message).accessibilityIdentifier("template.result") }
                PrimaryButton(title: L.t("template.import"), id: "template.import", disabled: parsed == nil || importing) {
                    guard let parsed, !importing else { return }
                    importing = true
                    Task {
                        defer { importing = false }
                        do {
                            let updated = try await model.apply { try $0.importTemplates(parsed) }
                            message = L.t(updated ? "template.added" : "template.duplicate")
                        } catch { message = L.t("error.storage") }
                    }
                }
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("template.open"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
