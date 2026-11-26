import CoreImage
import UIKit

enum AppLinks {
    static var storeID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return id
    }

    static var download: String {
        storeID.map { "https://apps.apple.com/app/id\($0)" }
            ?? "https://hgsldswk-alt.github.io/screenshotdue-support/"
    }
}

struct ShareCardContent {
    let counts: ProgressCounts
    let milestone: Bool
    let appName: String
    let download: String
    let isPlaceholder: Bool
    var series = false
}

enum ShareCard {
    static let size = CGSize(width: 1080, height: 1350)

    static func qr(_ payload: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }

    static func render(_ content: ShareCardContent) -> UIImage {
        let paper = UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        let ink = UIColor(red: 0.14, green: 0.17, blue: 0.15, alpha: 1)
        let accent = UIColor(red: 0.24, green: 0.40, blue: 0.31, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let qrImage = qr(content.download)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.90, green: 0.93, blue: 0.90, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 52, y: 60, width: 976, height: 1230), cornerRadius: 48).fill()
            func draw(_ value: String, x: CGFloat = 108, y: CGFloat, width: CGFloat = 860,
                      height: CGFloat = 105, size: CGFloat, color: UIColor, bold: Bool = true) {
                (value as NSString).draw(with: CGRect(x: x, y: y, width: width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: UIFont.systemFont(ofSize: size, weight: bold ? .bold : .medium), .foregroundColor: color],
                    context: nil)
            }
            draw(content.appName, y: 128, size: 44, color: accent)
            if content.milestone {
                draw(100.formatted(), y: 292, height: 192, size: 172, color: ink)
                draw(L.t("share.cleared"), y: 500, size: 55, color: ink)
            } else {
                draw(L.t("share.week"), y: 238, size: 61, color: ink)
                draw(content.counts.cleared.formatted(), y: 355, height: 165, size: 147, color: ink)
                draw(L.t("share.cleared"), y: 537, size: 50, color: ink)
                draw(content.counts.done.formatted(), y: 649, height: 150, size: 126, color: ink)
                draw(L.t("share.done"), y: 798, size: 50, color: ink)
            }

            if let qrImage {
                UIColor.white.setFill()
                context.fill(CGRect(x: 108, y: 963, width: 228, height: 228))
                let edge = qrImage.width * (192 / qrImage.width)
                let offset = CGFloat((228 - edge) / 2)
                context.cgContext.interpolationQuality = .none
                UIImage(cgImage: qrImage).draw(in: CGRect(x: 108 + offset, y: 963 + offset,
                                                            width: CGFloat(edge), height: CGFloat(edge)))
            }
            draw(L.t(content.isPlaceholder ? "share.qrPlaceholder" : "share.qr"), x: 365, y: 990, width: 555,
                 size: 36, color: ink, bold: false)
            draw("#ScreenshotToDo", x: 365, y: 1072, width: 555, size: 39, color: accent)
            if content.series {
                draw(L.t("share.series"), x: 365, y: 1140, width: 555, size: 31, color: accent, bold: false)
            }
        }
    }
}
