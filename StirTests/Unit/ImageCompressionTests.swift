import UIKit
import XCTest
@testable import Stir

@MainActor
final class ImageCompressionTests: XCTestCase {
    func test_jpegCapsPixelDimensionsForEverySourceScale() throws {
        let raster = makeRaster(size: CGSize(width: 2400, height: 1800))
        for sourceScale: CGFloat in [1, 2, 3] {
            try autoreleasepool {
                let source = UIImage(cgImage: raster, scale: sourceScale, orientation: .up)
                let data = try ImageCompression.jpeg(source, maxLongEdge: 1600, quality: 0.85)
                let output = try XCTUnwrap(UIImage(data: data)?.cgImage)
                XCTAssertEqual(output.width, 1600, "Source scale: \(sourceScale)")
                XCTAssertEqual(output.height, 1200, "Source scale: \(sourceScale)")
            }
        }
    }

    func test_jpegKeepsSmallImagesAtTheirOriginalPixelDimensions() throws {
        let raster = makeRaster(size: CGSize(width: 1200, height: 900))
        for sourceScale: CGFloat in [1, 3] {
            let source = UIImage(cgImage: raster, scale: sourceScale, orientation: .up)
            let data = try ImageCompression.jpeg(source, maxLongEdge: 1600, quality: 0.85)
            let output = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(output.width, 1200)
            XCTAssertEqual(output.height, 900)
        }
    }

    func test_jpegCapsPortraitLongEdgeAndPreservesAspectRatio() throws {
        let raster = makeRaster(size: CGSize(width: 1800, height: 2400))
        let source = UIImage(cgImage: raster, scale: 3, orientation: .up)
        let data = try ImageCompression.jpeg(source, maxLongEdge: 1600, quality: 0.85)
        let output = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(output.width, 1200)
        XCTAssertEqual(output.height, 1600)
    }

    func test_jpegNormalizesRotatedSourceWithinPixelCap() throws {
        let raster = makeRaster(size: CGSize(width: 2400, height: 1800))
        let source = UIImage(cgImage: raster, scale: 3, orientation: .right)
        let data = try ImageCompression.jpeg(source, maxLongEdge: 1600, quality: 0.85)
        let image = try XCTUnwrap(UIImage(data: data))
        let output = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(max(output.width, output.height), 1600)
        XCTAssertEqual(min(output.width, output.height), 1200)
        XCTAssertEqual(image.imageOrientation, .up)
    }

    private func makeRaster(size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }
}
