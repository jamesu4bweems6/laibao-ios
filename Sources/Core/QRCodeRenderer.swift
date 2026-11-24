import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure Apple `CoreImage` QR code generator (`CIQRCodeGenerator`) with zero third-party dependencies.
public enum QRCodeRenderer {
    /// Generates a crisp, nearest-neighbor scaled `CGImage` for `content`.
    /// Returns `nil` if `content` is empty or CoreImage fails to render.
    public static func renderCGImage(from content: String, size: Int = 256) -> CGImage? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let payload = trimmed.data(using: .utf8) else {
            return nil
        }

        let targetSize = max(64, min(1024, size))
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }
        let extent = outputImage.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let scale = max(1.0, floor(CGFloat(targetSize) / max(extent.width, extent.height)))
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// Generates PNG image bytes (`\x89PNG...`) for `content`.
    public static func renderPNGData(from content: String, size: Int = 256) -> Data? {
        guard let cgImage = renderCGImage(from: content, size: size) else {
            return nil
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }
}
