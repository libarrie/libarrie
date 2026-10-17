import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to queue: exact bytes to upload plus their checksums.
public struct PreparedImage: Sendable, Equatable {
    public var data: Data
    /// `image/jpeg` or `image/png`.
    public var contentType: String
    public var sha256: String
    public var md5: String
    public var pixelWidth: Int
    public var pixelHeight: Int
}

public enum ImagePreparationError: Error, Equatable, LocalizedError {
    case unreadable
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This photo could not be read. Try a JPEG or PNG, or take the photo again."
        case .tooLarge: "This photo is too large to upload, even after resizing."
        }
    }
}

/// Prepares captured or imported photos (section 7, step 1 and section 6):
///
/// - JPEG and PNG keep their exact bytes when nothing must change.
/// - HEIC/HEIF and other formats are converted to JPEG with the platform's
///   own decoders (ImageIO); the product bundles no HEIF decoder.
/// - Location (GPS) metadata is removed by default; other metadata, including
///   the orientation tag (the server applies it to derived images), is kept.
/// - Images over the server's byte limit are re-encoded smaller.
public struct ImagePreparer: Sendable {
    public var keepLocation: Bool
    public var maxBytes: Int
    public var jpegQuality: Double = 0.9

    public init(keepLocation: Bool = false, maxBytes: Int = 20_000_000) {
        self.keepLocation = keepLocation
        self.maxBytes = maxBytes
    }

    public func prepare(_ input: Data) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              let type = CGImageSourceGetType(source).map({ $0 as String }),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ImagePreparationError.unreadable }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let hasLocation = properties[kCGImagePropertyGPSDictionary] != nil

        let passthrough = [UTType.jpeg.identifier, UTType.png.identifier].contains(type)
        var data: Data
        var contentType: String
        if passthrough && (keepLocation || !hasLocation) && input.count <= maxBytes {
            data = input
            contentType = type == UTType.png.identifier ? "image/png" : "image/jpeg"
        } else if passthrough && input.count <= maxBytes {
            // Lossless metadata edit: same pixels, no location.
            data = try copyWithoutLocation(source, type: type)
            contentType = type == UTType.png.identifier ? "image/png" : "image/jpeg"
        } else {
            data = try encodeJPEG(source, properties: properties, maxDimension: nil, quality: jpegQuality)
            contentType = "image/jpeg"
        }
        // Too large: lower the quality, then step the longest side down,
        // keeping handwriting legible (at least 1,600 px).
        var dimension = max(width, height)
        var quality = jpegQuality
        while data.count > maxBytes {
            if quality > 0.7 {
                quality -= 0.1
            } else {
                dimension = dimension * 3 / 4
                guard dimension >= 1600 else { throw ImagePreparationError.tooLarge }
            }
            data = try encodeJPEG(source, properties: properties,
                                  maxDimension: dimension < max(width, height) ? dimension : nil, quality: quality)
            contentType = "image/jpeg"
        }
        let size = Self.pixelSize(of: data) ?? (width, height)
        return PreparedImage(
            data: data, contentType: contentType,
            sha256: Self.sha256Hex(data), md5: Self.md5Hex(data),
            pixelWidth: size.0, pixelHeight: size.1)
    }

    private func copyWithoutLocation(_ source: CGImageSource, type: String) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            throw ImagePreparationError.unreadable
        }
        // Copy every metadata tag except the GPS namespace (orientation,
        // capture time and camera details stay).
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let edited = CGImageMetadataCreateMutableCopy(metadata)
        else { throw ImagePreparationError.unreadable }
        var gpsPaths: [CFString] = []
        // GPS tags are `exif:GPS…` properties in the EXIF namespace.
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            if (path as String).hasPrefix("exif:GPS") { gpsPaths.append(path) }
            return true
        }
        for path in gpsPaths { CGImageMetadataRemoveTagWithPath(edited, nil, path) }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: edited,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw ImagePreparationError.unreadable
        }
        return output as Data
    }

    private func encodeJPEG(_ source: CGImageSource, properties: [CFString: Any], maxDimension: Int?, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePreparationError.unreadable
        }
        var metadata = properties
        if !keepLocation { metadata[kCGImagePropertyGPSDictionary] = kCFNull }
        metadata[kCGImageDestinationLossyCompressionQuality] = quality
        if let maxDimension {
            // A thumbnail-sized decode applies the orientation itself.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ImagePreparationError.unreadable
            }
            metadata[kCGImagePropertyOrientation] = 1
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                metadata[kCGImagePropertyTIFFDictionary] = tiff
            }
            CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ImagePreparationError.unreadable }
        return output as Data
    }

    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Base64(hex: String) -> String {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }
}
