import CoreImage
import Foundation
import ImageIO

protocol FrameEncoding: Sendable {
    func encode(_ frame: DisplayFrame, orientation: DeviceOrientation) throws -> Data
}

final class JPEGFrameEncoder: FrameEncoding, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func encode(_ frame: DisplayFrame, orientation: DeviceOrientation) throws -> Data {
        try autoreleasepool {
            let rotation: CGImagePropertyOrientation
            switch orientation {
            case .portrait: rotation = .up
            case .landscapeLeft: rotation = .right
            case .portraitUpsideDown: rotation = .down
            case .landscapeRight: rotation = .left
            }
            let image = CIImage(ioSurface: frame.surface).oriented(rotation)
            // Keep bandwidth bounded on large iPads as well as iPhones.
            let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let data = context.jpegRepresentation(of: scaled, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]) else {
                throw SimulatorError.message("Could not encode the Device display.")
            }
            return data
        }
    }
}
