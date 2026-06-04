import CoreGraphics

/// Helpers for preparing an image-wallpaper background. The render path draws
/// the wallpaper full-screen with a plain 0…1 texCoord fill, so the image must
/// already match the output aspect ratio — otherwise it would stretch. We do
/// an aspect-fill (center-crop) here, on the CPU, once per composition.
public enum BackgroundImage {

    /// The center sub-rect of an `imageWidth`×`imageHeight` image that matches
    /// `outputSize`'s aspect ratio (cover / aspect-fill). In image pixel
    /// coordinates. Pure + unit-tested.
    public static func cropRect(imageWidth iw: Int, imageHeight ih: Int, outputSize: CGSize) -> CGRect {
        let w = CGFloat(iw), h = CGFloat(ih)
        guard w > 0, h > 0, outputSize.width > 0, outputSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }
        let target = outputSize.width / outputSize.height
        let current = w / h
        var cropW = w, cropH = h
        if current > target {
            // Image is wider than the output → trim the sides.
            cropW = (h * target).rounded()
        } else if current < target {
            // Image is taller → trim top/bottom.
            cropH = (w / target).rounded()
        }
        let x = ((w - cropW) / 2).rounded(.down)
        let y = ((h - cropH) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: cropW, height: cropH)
    }

    /// Center-crop `image` to `outputSize`'s aspect ratio. Returns the original
    /// if it already matches or if cropping fails.
    public static func aspectCropped(_ image: CGImage, toAspectOf outputSize: CGSize) -> CGImage {
        let rect = cropRect(imageWidth: image.width, imageHeight: image.height, outputSize: outputSize)
        if Int(rect.width) == image.width && Int(rect.height) == image.height {
            return image
        }
        return image.cropping(to: rect) ?? image
    }
}
