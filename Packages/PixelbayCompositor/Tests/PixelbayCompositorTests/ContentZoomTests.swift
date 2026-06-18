import XCTest
import PixelbayCore
@testable import PixelbayCompositor

/// Content-zoom: in free-form `.custom` layouts the zoom magnifies the footage
/// inside the FIXED screen window (a source crop) instead of moving/growing the
/// window. Preset (pip/split) layouts keep the classic destination-rect zoom —
/// covered by `EffectEvaluatorTests`, which must keep passing unchanged.
final class ContentZoomTests: XCTestCase {

    private let outputSize = CGSize(width: 1920, height: 1080)

    private func customBase(screen: LayerRect) -> ResolvedLayout {
        ResolvedLayout(
            outputSize: outputSize,
            background: .clear,
            screen: screen,
            screenCornerRadius: 0,
            webcam: nil,
            webcamShape: .rectangle,
            webcamCornerRadius: 0,
            zoomTargetsContent: true
        )
    }

    private func centerZoom(factor: Double) -> EffectKeyframe {
        EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: factor,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
    }

    // MARK: - cropUV helper

    func test_cropUV_identityTransform_isIdentity() {
        let crop = EffectEvaluator.cropUV(
            forVirtualTransform: AppliedZoomTransform(scale: 1, x: 0, y: 0),
            outputSize: outputSize
        )
        XCTAssertEqual(crop.x, 1, accuracy: 1e-5)
        XCTAssertEqual(crop.y, 1, accuracy: 1e-5)
        XCTAssertEqual(crop.z, 0, accuracy: 1e-5)
        XCTAssertEqual(crop.w, 0, accuracy: 1e-5)
    }

    func test_cropUV_2xCentered_samplesCenterHalf() {
        // 2× zoom about the center on a full frame → virtual transform
        // (scale 2, translate (-W/2, -H/2)). Crop should sample the centre 50%
        // window: scale 0.5, offset 0.25 (so srcUV(0.5) == 0.5).
        let crop = EffectEvaluator.cropUV(
            forVirtualTransform: AppliedZoomTransform(scale: 2, x: -960, y: -540),
            outputSize: outputSize
        )
        XCTAssertEqual(crop.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(crop.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(crop.z, 0.25, accuracy: 1e-5)
        XCTAssertEqual(crop.w, 0.25, accuracy: 1e-5)
        // Centre of the window maps to the centre of the source.
        XCTAssertEqual(0.5 * crop.x + crop.z, 0.5, accuracy: 1e-5)
    }

    // MARK: - applyZoom content-crop branch

    func test_apply_custom_keepsWindowFixed_andSetsCrop() {
        // A 50%, off-centre window — the window must NOT move/scale during zoom.
        let window = LayerRect(origin: CGPoint(x: 192, y: 108), size: CGSize(width: 960, height: 540))
        let base = customBase(screen: window)
        let result = EffectEvaluator.apply(keyframes: [centerZoom(factor: 2.0)], baseLayout: base, atTime: 1)

        // Window rect is untouched.
        XCTAssertEqual(result.screen.origin.x, 192, accuracy: 0.5)
        XCTAssertEqual(result.screen.origin.y, 108, accuracy: 0.5)
        XCTAssertEqual(result.screen.size.width, 960, accuracy: 0.5)
        XCTAssertEqual(result.screen.size.height, 540, accuracy: 0.5)

        // Content is magnified via the source crop (2× → 0.5 scale, centre).
        XCTAssertEqual(result.screenCropUV.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(result.screenCropUV.z, 0.25, accuracy: 1e-4)
        // Virtual full-frame rect is carried for the spring.
        XCTAssertNotNil(result.screenZoomVirtualRect)
        XCTAssertEqual(result.screenZoomVirtualRect?.size.width ?? 0, 3840, accuracy: 1)
    }

    func test_apply_custom_magnificationEqualsZoomFactor() {
        let window = LayerRect(origin: .zero, size: CGSize(width: 1920, height: 1080))
        let base = customBase(screen: window)
        let result = EffectEvaluator.apply(keyframes: [centerZoom(factor: 1.6)], baseLayout: base, atTime: 1)
        // magnification == 1 / cropScale should equal the zoom factor at full strength.
        let magnification = 1.0 / Double(result.screenCropUV.x)
        XCTAssertEqual(magnification, 1.6, accuracy: 1e-3)
        // The window still fills the canvas (unmoved).
        XCTAssertEqual(result.screen.size.width, 1920, accuracy: 0.5)
    }

    func test_apply_custom_noZoomKeyframe_leavesIdentityCrop() {
        let window = LayerRect(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 800, height: 450))
        let base = customBase(screen: window)
        let result = EffectEvaluator.apply(keyframes: [], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screenCropUV.x, 1, accuracy: 1e-5)
        XCTAssertEqual(result.screenCropUV.z, 0, accuracy: 1e-5)
        XCTAssertEqual(result.screen.origin.x, 100, accuracy: 0.5)
    }

    func test_apply_custom_longZoom_atLateTime_stillMagnifies() {
        // Mirrors the GUI repro: a long full-strength zoom, sampled at a late
        // playhead. If strength collapses to 0 here, the preview shows no zoom.
        let window = LayerRect(origin: CGPoint(x: 480, y: 270), size: CGSize(width: 960, height: 540))
        let base = customBase(screen: window)
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(25)),
            zoomFactor: 2.5,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 17)
        XCTAssertLessThan(Double(result.screenCropUV.x), 0.99, "crop should magnify at t=17 mid-zoom")
        XCTAssertNotNil(result.screenZoomVirtualRect)
    }

    // MARK: - non-custom path is untouched

    func test_apply_nonCustom_stillMovesRect() {
        // Preset full-screen layout (zoomTargetsContent == false) keeps the
        // classic destination-rect zoom: rect grows to 2× and recenters.
        let base = ResolvedLayout(
            outputSize: outputSize,
            background: .clear,
            screen: LayerRect(origin: .zero, size: outputSize),
            screenCornerRadius: 0,
            webcam: nil,
            webcamShape: .rectangle,
            webcamCornerRadius: 0
        )
        let result = EffectEvaluator.apply(keyframes: [centerZoom(factor: 2.0)], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, -960, accuracy: 1)
        // No crop in the classic path.
        XCTAssertEqual(result.screenCropUV.x, 1, accuracy: 1e-5)
        XCTAssertNil(result.screenZoomVirtualRect)
    }

    // MARK: - LayoutCalculator flag

    func test_resolve_zoomTargetsContent_trueOnlyForCustom() {
        let customPreset = LayoutPreset(mode: .custom(
            screen: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            webcam: nil
        ))
        let pipPreset = LayoutPreset(mode: .pip(position: .bottomRight, size: .medium))

        let custom = LayoutCalculator.resolve(preset: customPreset, outputSize: outputSize, hasWebcam: false)
        let pip = LayoutCalculator.resolve(preset: pipPreset, outputSize: outputSize, hasWebcam: false)

        XCTAssertTrue(custom.zoomTargetsContent)
        XCTAssertFalse(pip.zoomTargetsContent)
    }
}
