import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LibarrieKit

/// A test photo in `type` with GPS and orientation metadata.
func photo(_ type: UTType, width: Int = 800, height: Int = 600, gps: Bool = true, quality: Double = 0.9, block: Int = 8) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Noise keeps JPEG sizes realistic for the size-limit test.
    var generator = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: height, by: block) {
        for x in stride(from: 0, to: width, by: block) {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: x, y: y, width: block, height: block))
        }
    }
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: quality]
    if gps {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
        ]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
}

func properties(_ data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
}

@Suite struct ImageTests {
    @Test func jpegWithoutLocationKeepsItsExactBytes() throws {
        let input = photo(.jpeg, gps: false)
        let prepared = try ImagePreparer().prepare(input)
        #expect(prepared.data == input)
        #expect(prepared.contentType == "image/jpeg")
        #expect(prepared.sha256 == ImagePreparer.sha256Hex(input))
        #expect(prepared.md5.count == 32)
    }

    @Test func locationIsStrippedByDefaultAndOrientationKept() throws {
        let input = photo(.jpeg)
        #expect(properties(input)[kCGImagePropertyGPSDictionary] != nil)
        let prepared = try ImagePreparer().prepare(input)
        let output = properties(prepared.data)
        #expect(output[kCGImagePropertyGPSDictionary] == nil)
        #expect(output[kCGImagePropertyOrientation] as? Int == 6)
        #expect(prepared.pixelWidth == 800)
        // The user's setting can keep it.
        let kept = try ImagePreparer(keepLocation: true).prepare(input)
        #expect(kept.data == input)
    }

    @Test func heicBecomesJPEGWithoutLocation() throws {
        let input = photo(.heic)
        let prepared = try ImagePreparer().prepare(input)
        #expect(prepared.contentType == "image/jpeg")
        let source = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(properties(prepared.data)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func oversizedPhotosAreResizedToFit() throws {
        let input = photo(.jpeg, width: 4000, height: 3000, gps: false, block: 64)
        let limit = input.count * 3 / 4
        let prepared = try ImagePreparer(maxBytes: limit).prepare(input)
        #expect(prepared.data.count <= limit)
        #expect(prepared.contentType == "image/jpeg")
        #expect(max(prepared.pixelWidth, prepared.pixelHeight) >= 1600)
        // Beyond legibility the photo is refused rather than shrunk further.
        #expect(throws: ImagePreparationError.tooLarge) { try ImagePreparer(maxBytes: 10_000).prepare(input) }
    }

    @Test func unreadableInputIsRefused() {
        #expect(throws: ImagePreparationError.unreadable) { try ImagePreparer().prepare(Data("not an image".utf8)) }
    }
}
