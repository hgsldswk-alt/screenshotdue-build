import SwiftUI
import UIKit

enum DemoData {
    static let notificationTask = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    static let oldAssets = ["fixture.one", "fixture.two", "fixture.three"]
    private static let titles = ["demo.ticket", "demo.voucher", "demo.reply", "demo.travel"]

    static func photo(_ index: Int = 0) throws -> PreparedPhoto {
        let titleKey = titles[index % titles.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1150), format: format)
        let png = renderer.pngData { context in
            UIColor(red: 0.89, green: 0.88, blue: 0.83, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1150))
            let colors = [UIColor(red: 0.10, green: 0.24, blue: 0.23, alpha: 1),
                          UIColor(red: 0.34, green: 0.19, blue: 0.13, alpha: 1),
                          UIColor(red: 0.18, green: 0.30, blue: 0.51, alpha: 1)]
            colors[index % colors.count].setFill()
            UIBezierPath(roundedRect: CGRect(x: 48, y: 160, width: 804, height: 770), cornerRadius: 38).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 67, weight: .bold), .foregroundColor: UIColor.white
            ]
            (L.t(titleKey) as NSString).draw(in: CGRect(x: 100, y: 245, width: 705, height: 280), withAttributes: attributes)
            if let qr = ShareCard.qr("https://example.com/screenshotdue-demo") {
                UIImage(cgImage: qr).draw(in: CGRect(x: 100, y: 550, width: 250, height: 250))
            }
            (L.f("demo.mark", index + 1) as NSString).draw(at: CGPoint(x: 101, y: 995),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 35, weight: .medium), .foregroundColor: UIColor.darkGray])
        }
        return try PreparedPhoto(data: png)
    }

    static func seed(_ store: TaskStore) throws {
        guard Launch.has("-demo") || Launch.has("-demo-full") else { return }
        guard try store.snapshot().tasks.isEmpty else { return }
        let now = Date.now
        let calendar = CivilDay.calendar()
        let today = CivilDay(now, calendar: calendar)
        let offsets = Launch.has("-demo-full") ? Array(repeating: 1, count: 10) : [-1, 0, 1, 4]
        if Launch.has("-demo-full") {
            try store.change { $0.entitlement?.purchasedPro = true }
        }
        for (index, offset) in offsets.enumerated() {
            let id = try store.add(photo(index + 1), token: UUID(), purpose: L.t(titles[index % titles.count]),
                                   due: DueDate(day: today.adding(offset, in: calendar), hour: index == 1 ? 16 : 9))
            if index == 0 {
                try store.change { state in
                    if let first = state.tasks.firstIndex(where: { $0.id == id }) {
                        state.tasks[first].id = notificationTask
                        state.importTokens = state.importTokens.mapValues { $0 == id ? notificationTask : $0 }
                    }
                }
            }
        }
        if Launch.has("-demo-full") {
            try store.change { $0.entitlement?.purchasedPro = false }
        }
        if Launch.has("-review-previous-completion") {
            try store.complete(notificationTask, done: true, now: today.adding(-1, in: calendar).date(in: calendar))
        }
        if Launch.has("-demo-progress") {
            let id = try store.add(photo(15), token: UUID(), purpose: L.t("demo.reply"), due: DueDate(day: today))
            try store.complete(id, done: true)
            try store.change { state in
                for index in 1...23 { state.deletedAssets["demo-\(index)"] = now }
            }
        }
    }
}
