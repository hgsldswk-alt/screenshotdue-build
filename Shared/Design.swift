import SwiftUI

enum Theme {
    static let accent = Color(red: 111 / 255, green: 155 / 255, blue: 131 / 255)
    static let ink = Color(red: 36 / 255, green: 44 / 255, blue: 39 / 255)
    static let background = adaptive(0xFAF8F4, 0x181D19)
    static let paper = adaptive(0xFFFDF9, 0x242C27)
    static let line = adaptive(0xE5E1D8, 0x465048)
    static let text = adaptive(0x242C27, 0xF4F1E9)
    static let muted = adaptive(0x565D55, 0xBBC8BE)
    static let tint = adaptive(0xE7EEE6, 0x354B3D)
    static let danger = adaptive(0x82483D, 0xF6B0A1)
    static let forest = adaptive(0x305844, 0xC8E3D2)
    static let forestFill = Color(red: 0.21, green: 0.36, blue: 0.29)
    static let card = adaptive(0xFFFFFF, 0x242C27)
    static let ochre = adaptive(0x80541F, 0xF2C58E)
    static let ochreTint = adaptive(0xFAEAD3, 0x513D28)
    static let slate = adaptive(0x3C5C70, 0xBDD9E8)
    static let slateTint = adaptive(0xE8EFF4, 0x2B4150)
    static let dangerTint = adaptive(0xF9E6E0, 0x4C312A)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct HeroCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 48.0
    let due: Int
    let cleared: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.t("home.today")).font(.subheadline.weight(.semibold))
                    Text(L.f("home.heroCount", due.formatted()))
                        .font(.system(size: numberSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L.f("widget.count", due))

                StatusPill(title: L.f("home.heroCleared", cleared.formatted()), background: Theme.card,
                           foreground: Theme.forest, systemImage: "checkmark.circle.fill")
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize {
                illustration.accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.forest)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.32), Theme.tint, Theme.card],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
        }
        .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 4)
    }

    private var illustration: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Theme.card.opacity(0.65)).frame(width: 90, height: 90)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .medium))
                .rotationEffect(.degrees(-8))
                .frame(width: 90, height: 90)
            Image(systemName: "clock.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.ochre)
                .frame(width: 35, height: 35)
                .background(Theme.ochreTint, in: Circle())
        }
    }
}

struct StatusPill: View {
    let title: String
    let background: Color
    let foreground: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(background, in: Capsule())
    }
}

struct IconTile: View {
    let title: String
    let id: String
    let systemImage: String
    let color: Color
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Paper(elevated: true) {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                        .frame(width: 36, height: 36)
                        .background(tint, in: Circle())
                        .accessibilityHidden(true)
                    Text(title).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 38)
            }
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct EmptyIllustration: View {
    var body: some View {
        ZStack {
            Image(systemName: "photo")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.forest)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.slate)
                .background(Theme.slateTint, in: Circle())
                .offset(x: 16, y: 11)
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ochre)
                .offset(x: -16, y: -14)
        }
        .frame(width: 58, height: 52)
        .background(Theme.tint, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    @ScaledMetric(relativeTo: .title3) private var fontSize = 20.0
    let title: String
    let id: String
    var disabled = false
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
            .font(.system(size: fontSize, weight: .bold))
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Theme.accent.opacity(disabled ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 14))
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }
}

struct TextAction: View {
    let title: String
    let id: String
    var systemImage: String?
    var color = Theme.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .accessibilityIdentifier(id)
    }
}

struct Paper<Content: View>: View {
    var elevated = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 17)
                    .fill(elevated ? Theme.card : Theme.paper)
                    .shadow(color: Theme.ink.opacity(elevated ? 0.08 : 0), radius: 12, y: 4)
            }
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(Theme.line).allowsHitTesting(false) }
    }
}

enum DateText {
    static func day(_ day: CivilDay) -> String {
        day.date(in: CivilDay.calendar()).formatted(.dateTime.month(.abbreviated).day())
    }

    static func clock(_ due: DueDate) -> String {
        due.date(in: CivilDay.calendar()).formatted(.dateTime.hour().minute())
    }

    static func short(_ due: DueDate, now: Date = .now) -> String {
        let today = CivilDay(now)
        if due.day < today { return L.f("due.pastDate", day(due.day)) }
        if due.day == today { return L.f("due.todayTime", clock(due)) }
        return L.f("due.dayTime", day(due.day), clock(due))
    }
}
