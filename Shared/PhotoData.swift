import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct PreparedPhoto: Sendable {
    let original: Data
    let thumbnail: Data
    let fingerprint: String

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, PhotoData.uncached),
              CGImageSourceGetCount(source) > 0,
              let image = PhotoData.thumbnail(source, edge: 400),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw StorageError.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw StorageError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StorageError.invalidImage }
        original = data
        thumbnail = encoded as Data
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PhotoData {
    static let uncached = [kCGImageSourceShouldCache: false] as CFDictionary

    static func thumbnail(_ source: CGImageSource, edge: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func preview(_ data: Data, edge: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, uncached),
              let image = thumbnail(source, edge: edge) else { return nil }
        return UIImage(cgImage: image)
    }

    static func image(at url: URL, edge: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, uncached),
              let image = thumbnail(source, edge: edge) else { return nil }
        return UIImage(cgImage: image)
    }
}
