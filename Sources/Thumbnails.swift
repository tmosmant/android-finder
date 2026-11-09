import AppKit
import ImageIO

final class ThumbnailResult {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

enum Thumbnails {
    static let imageLimit = 4 * 1024 * 1024

    static func key(for entry: AndroidEntry) -> NSString {
        "\(entry.Size):\(entry.Handle ?? 0):\(entry.FullPath)" as NSString
    }

    static func canLoad(_ entry: AndroidEntry, wireless: Bool) -> Bool {
        let type = fileType(entry)
        if wireless { return type.conforms(to: .image) && entry.Size <= imageLimit }
        return entry.Handle != nil && (type.conforms(to: .image) || type.conforms(to: .movie))
    }

    static func load(_ entry: AndroidEntry, mtp: MTP, wireless: WirelessStorage?,
                     request: OperationRequest) throws -> ThumbnailResult {
        let limit = fileType(entry).conforms(to: .image) && entry.Size <= imageLimit ? imageLimit : 0
        let data: Data
        if let wireless {
            data = try wireless.thumbnail(entry, limit: limit, request: request)
        } else if let handle = entry.Handle {
            data = try mtp.command(["thumbnail", String(handle), entry.Name, String(limit)], request: request)
        } else {
            return ThumbnailResult(nil)
        }
        guard !data.isEmpty, data.count <= imageLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 64_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240
              ] as CFDictionary) else { return ThumbnailResult(nil) }
        return ThumbnailResult(NSImage(cgImage: image, size: .zero))
    }
}
