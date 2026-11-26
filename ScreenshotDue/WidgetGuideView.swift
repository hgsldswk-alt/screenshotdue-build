import SwiftUI

struct WidgetGuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            let preview = data
            VStack(alignment: .leading, spacing: 20) {
                Text(L.t("widget.help")).font(.subheadline).foregroundStyle(Theme.muted)
                Paper(elevated: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading("widget.home", icon: "square.grid.2x2.fill", color: Theme.slate, tint: Theme.slateTint)
                        homePreview(preview)
                    }
                }
                Paper(elevated: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading("widget.lock", icon: "lock.fill", color: Theme.forest, tint: Theme.tint)
                        lockPreview(preview)
                        Text(L.t("settings.widgetPrivacy")).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                if !model.hasPro { Text(L.t("widget.locked")).accessibilityIdentifier("widget.locked") }
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("widget.guide"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func heading(_ title: String, icon: String, color: Color, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(tint, in: Circle())
                .accessibilityHidden(true)
            Text(L.t(title)).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }

    private func homePreview(_ preview: TodayWidgetData) -> some View {
        TodayWidgetPanel(data: preview, lock: false, limit: 3)
            .padding(13)
            .frame(maxWidth: 285, minHeight: 112)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: Theme.ink.opacity(0.12), radius: 8, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("widget.homePreview")
            .padding(13)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Theme.tint, Theme.slateTint], startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
            }
    }

    private func lockPreview(_ preview: TodayWidgetData) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption).accessibilityHidden(true)
            TodayWidgetPanel(data: preview, lock: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 190, minHeight: 52)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("widget.lockPreview")
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Theme.forestFill, Theme.ink], startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
    }

    private var data: TodayWidgetData {
        TodayWidgetData.prepare(state: model.state, at: model.now, readThumbnail: { _ in nil })
    }
}
