import CoreGraphics

/// Physical frame orientation, independent of the guest app's supported layout.
enum DeviceOrientation: String, Sendable {
    case portrait, landscapeLeft, portraitUpsideDown, landscapeRight

    var degrees: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 90
        case .portraitUpsideDown: 180
        case .landscapeRight: 270
        }
    }

    var rotatedRight: DeviceOrientation {
        switch self {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .portraitUpsideDown
        case .portraitUpsideDown: .landscapeRight
        case .landscapeRight: .portrait
        }
    }

    /// Undo the displayed rotation to address the portrait-native digitizer.
    func nativePoint(_ shown: CGPoint) -> CGPoint {
        switch self {
        case .portrait: shown
        case .landscapeLeft: CGPoint(x: shown.y, y: 1 - shown.x)
        case .portraitUpsideDown: CGPoint(x: 1 - shown.x, y: 1 - shown.y)
        case .landscapeRight: CGPoint(x: 1 - shown.y, y: shown.x)
        }
    }

    /// The guest's Purple workspace protocol uses a different order.
    var gsEventValue: UInt32 {
        switch self {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        case .landscapeLeft: 4
        }
    }
}
