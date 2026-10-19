import Foundation
import CoreGraphics

public struct DisplayGeometry: Equatable {
    public let id: UInt32
    /// WindowServer coordinates: origin at the primary display's top-left.
    public let frame: CGRect
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }

    public static func quartzFrame(appKitFrame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: appKitFrame.minX, y: primaryTop - appKitFrame.maxY,
               width: appKitFrame.width, height: appKitFrame.height)
    }

    public static func owner(of window: CGRect, displays: [DisplayGeometry]) -> UInt32? {
        guard !displays.isEmpty else { return nil }
        let center = CGPoint(x: window.midX, y: window.midY)
        return displays.max { a, b in
            func area(_ display: DisplayGeometry) -> CGFloat {
                let rect = display.frame.intersection(window)
                return rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
            }
            let aa = area(a), ab = area(b)
            if aa != ab { return aa < ab }
            if a.frame.contains(center) != b.frame.contains(center) { return b.frame.contains(center) }
            func distance(_ display: DisplayGeometry) -> CGFloat {
                let x = min(max(center.x, display.frame.minX), display.frame.maxX)
                let y = min(max(center.y, display.frame.minY), display.frame.maxY)
                return pow(center.x - x, 2) + pow(center.y - y, 2)
            }
            return distance(a) > distance(b)
        }?.id
    }
}

public enum PreviewGeometry {
    public static func outputSize(window: CGSize, limit: CGSize) -> CGSize {
        guard window.width.isFinite, window.height.isFinite, window.width > 0, window.height > 0 else { return limit }
        let scale = min(min(1024, limit.width) / window.width, min(768, limit.height) / window.height)
        return CGSize(width: max(2, floor(window.width * scale)), height: max(2, floor(window.height * scale)))
    }

    /// ScreenCaptureKit describes content/bounding rects in points in surface
    /// coordinates. Convert to pixels before stripping the capture padding.
    public static func cropRect(content: CGRect, scaleFactor: CGFloat, surface: CGSize) -> CGRect? {
        guard scaleFactor.isFinite, scaleFactor > 0, content.width > 0, content.height > 0,
              [content.minX, content.minY, content.width, content.height].allSatisfy(\.isFinite) else { return nil }
        let pixels = content.applying(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)).integral
            .intersection(CGRect(origin: .zero, size: surface))
        return pixels.isNull || pixels.isEmpty ? nil : pixels
    }

    public static func centeredFrame(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}
