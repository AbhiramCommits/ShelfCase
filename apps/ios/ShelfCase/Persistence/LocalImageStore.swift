import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Writes item photos into the app container and hands back a *relative* path.
///
/// Relative paths matter: the container's absolute path changes between installs,
/// and an absolute path persisted in SwiftData would silently point at nothing
/// after an app update. Everything the UI does goes through `loadImage`, so the
/// absolute prefix is re-resolved on every read.
enum LocalImageStore {
    static let directoryName = "ItemImages"

    enum StoreError: LocalizedError {
        case encodingFailed
        case insufficientSpace(requiredBytes: Int, availableBytes: Int)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "The photo could not be encoded."
            case .insufficientSpace(let required, let available):
                return "Not enough free space: need \(required) bytes, \(available) available."
            }
        }
    }

    /// Container-relative directory, created on demand.
    static func directoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Persist a photo and return the relative path to store on the item.
    ///
    /// Refuses to write when free space is below a safety margin, so a full disk
    /// degrades into a clear error instead of a truncated JPEG.
    @discardableResult
    static func save(image: PlatformImage, quality: CGFloat = 0.82) throws -> String {
        guard let data = encode(image, quality: quality) else {
            throw StoreError.encodingFailed
        }
        let required = data.count + 8 * 1_024 * 1_024  // data + headroom
        let available = availableCapacityBytes()
        if available > 0, available < required {
            throw StoreError.insufficientSpace(requiredBytes: required, availableBytes: available)
        }

        let fileName = "\(UUID().uuidString.lowercased()).jpg"
        let url = try directoryURL().appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return "\(directoryName)/\(fileName)"
    }

    static func loadImage(relativePath: String) -> Image? {
        guard let data = try? Data(contentsOf: absoluteURL(for: relativePath)) else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    static func absoluteURL(for relativePath: String) -> URL {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(relativePath)
    }

    static func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: absoluteURL(for: relativePath))
    }

    static func availableCapacityBytes() -> Int {
        let url = (try? directoryURL()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Encoding

    private static func encode(_ image: PlatformImage, quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: quality)
        #elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return nil
        #endif
    }
}
