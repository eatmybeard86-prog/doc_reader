import UIKit
import ImageIO
import CoreImage

enum Images {
    /// Розміри зображення в пікселях з урахуванням повороту з EXIF.
    static func orientedSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 && orientation <= 8 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Зменшене зображення шириною не більше [width] пікселів, повернуте згідно з EXIF.
    static func downsample(_ source: CGImageSource, width: CGFloat) -> UIImage? {
        guard let size = orientedSize(source) else { return nil }
        let maxSide = max(size.width, size.height)
        let scale = min(1, width / size.width)
        let maxPixel = max(16, Int((maxSide * scale).rounded()))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    static func downsample(url: URL, width: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(src, width: width)
    }

    static func downsample(data: Data, width: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(src, width: width)
    }
}

/// Перефарбування растрових сторінок під тему: світле → колір сторінки, темне → колір тексту.
enum Recolor {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let lock = NSLock()

    static func apply(_ image: UIImage, theme: ReaderTheme) -> UIImage {
        guard theme.recolor, let cg = image.cgImage else { return image }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIFalseColor") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: theme.ink), forKey: "inputColor0")
        filter.setValue(CIColor(color: theme.page), forKey: "inputColor1")
        guard let output = filter.outputImage else { return image }
        lock.lock()
        defer { lock.unlock() }
        guard let result = context.createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: result, scale: image.scale, orientation: .up)
    }
}
