import XCTest
import PixelbayCore
@testable import PixelbayCompositor

final class LayoutCalculatorTests: XCTestCase {
    func test_screenLayer_fillsOutput() {
        let layout = LayoutCalculator.phase1Layout(
            outputSize: CGSize(width: 1920, height: 1080),
            includeWebcam: false
        )
        XCTAssertEqual(layout.screen.origin, .zero)
        XCTAssertEqual(layout.screen.size, CGSize(width: 1920, height: 1080))
    }

    func test_webcamOmitted_whenNotIncluded() {
        let layout = LayoutCalculator.phase1Layout(
            outputSize: CGSize(width: 1920, height: 1080),
            includeWebcam: false
        )
        XCTAssertNil(layout.webcam)
    }

    func test_webcam_landsBottomRight_withMargin_atFixedSize() {
        let layout = LayoutCalculator.phase1Layout(
            outputSize: CGSize(width: 1920, height: 1080),
            includeWebcam: true
        )
        let webcam = try! XCTUnwrap(layout.webcam)
        XCTAssertEqual(webcam.size, LayoutCalculator.webcamSize)
        // Bottom-right: maxX/maxY of the webcam should equal output minus margin.
        XCTAssertEqual(webcam.maxX, 1920 - LayoutCalculator.webcamMargin, accuracy: 0.001)
        XCTAssertEqual(webcam.maxY, 1080 - LayoutCalculator.webcamMargin, accuracy: 0.001)
    }

    func test_webcamCornerRadius_isPhase1Constant() {
        let layout = LayoutCalculator.phase1Layout(
            outputSize: CGSize(width: 1920, height: 1080),
            includeWebcam: true
        )
        XCTAssertEqual(layout.webcamCornerRadius, LayoutCalculator.webcamCornerRadius)
    }

    func test_webcamPosition_scalesWithOutput() {
        // At a smaller output size the webcam should still hug the bottom-right
        // and stay at its fixed pixel size — Phase 1 doesn't scale the cam
        // with resolution. Phase 3a is where the cam becomes scale-aware.
        let layout = LayoutCalculator.phase1Layout(
            outputSize: CGSize(width: 1280, height: 720),
            includeWebcam: true
        )
        let webcam = try! XCTUnwrap(layout.webcam)
        XCTAssertEqual(webcam.size, LayoutCalculator.webcamSize)
        XCTAssertEqual(webcam.maxX, 1280 - LayoutCalculator.webcamMargin, accuracy: 0.001)
        XCTAssertEqual(webcam.maxY, 720 - LayoutCalculator.webcamMargin, accuracy: 0.001)
    }

    func test_outputSize_propagatesToLayout() {
        let layout = LayoutCalculator.phase1Layout(
            outputSize: CGSize(width: 3840, height: 2160),
            includeWebcam: true
        )
        XCTAssertEqual(layout.outputSize, CGSize(width: 3840, height: 2160))
        XCTAssertEqual(layout.screen.size, CGSize(width: 3840, height: 2160))
    }

    func test_layerKind_allCases_screen_and_webcam() {
        XCTAssertEqual(LayerKind.allCases, [.screen, .webcam])
    }

    // MARK: - Phase 3a resolve(preset:)

    func test_resolve_phase1DefaultPreset_matchesPhase1Layout() {
        let resolved = LayoutCalculator.resolve(
            preset: .phase1Default,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertEqual(resolved.background, .clear)
        XCTAssertEqual(resolved.screen.origin, .zero)
        XCTAssertEqual(resolved.screen.size, CGSize(width: 1920, height: 1080))
        let cam = try! XCTUnwrap(resolved.webcam)
        // Phase 1 default cam at 1920 wide: width = 1920 / 8 = 240, height 240 * 9/16 = 135.
        XCTAssertEqual(cam.size, CGSize(width: 240, height: 135))
        XCTAssertEqual(cam.maxX, 1920 - LayoutCalculator.webcamMargin3a, accuracy: 1)
        XCTAssertEqual(cam.maxY, 1080 - LayoutCalculator.webcamMargin3a, accuracy: 1)
        XCTAssertEqual(resolved.webcamShape, .rectangle)
        XCTAssertEqual(resolved.webcamCornerRadius, 12)
    }

    func test_resolve_pip_topLeft_anchorsCorrectly() {
        let preset = LayoutPreset(mode: .pip(position: .topLeft, size: .medium))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        let cam = try! XCTUnwrap(resolved.webcam)
        XCTAssertEqual(cam.minX, LayoutCalculator.webcamMargin3a, accuracy: 1)
        XCTAssertEqual(cam.minY, LayoutCalculator.webcamMargin3a, accuracy: 1)
    }

    func test_resolve_pip_center_anchorsCorrectly() {
        let preset = LayoutPreset(mode: .pip(position: .center, size: .medium))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        let cam = try! XCTUnwrap(resolved.webcam)
        XCTAssertEqual(cam.midX, 1920 / 2, accuracy: 1)
        XCTAssertEqual(cam.midY, 1080 / 2, accuracy: 1)
    }

    func test_resolve_pip_largeSize_isBiggerThanMedium() {
        let med = LayoutCalculator.resolve(
            preset: LayoutPreset(mode: .pip(position: .bottomRight, size: .medium)),
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        let lg = LayoutCalculator.resolve(
            preset: LayoutPreset(mode: .pip(position: .bottomRight, size: .large)),
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertGreaterThan(lg.webcam!.size.width, med.webcam!.size.width)
    }

    func test_resolve_pip_noWebcam_yieldsNilCam() {
        let resolved = LayoutCalculator.resolve(
            preset: LayoutPreset(mode: .pip(position: .bottomRight, size: .medium)),
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: false
        )
        XCTAssertNil(resolved.webcam)
        XCTAssertEqual(resolved.screen.size, CGSize(width: 1920, height: 1080))
    }

    func test_resolve_splitHorizontal_screenLeft_partitionsOutputCleanly() {
        let preset = LayoutPreset(mode: .splitHorizontal(screenSide: .left, screenFraction: 0.7))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertEqual(resolved.screen.origin, .zero)
        XCTAssertEqual(resolved.screen.size.width, floor(1920 * 0.7), accuracy: 1)
        XCTAssertEqual(resolved.screen.size.height, 1080)
        let cam = try! XCTUnwrap(resolved.webcam)
        XCTAssertEqual(cam.minX, resolved.screen.maxX, accuracy: 1)
        XCTAssertEqual(cam.size.height, 1080)
        XCTAssertEqual(resolved.screen.maxX + cam.size.width, 1920, accuracy: 1)
    }

    func test_resolve_splitHorizontal_screenRight_mirrorsLayout() {
        let preset = LayoutPreset(mode: .splitHorizontal(screenSide: .right, screenFraction: 0.7))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        let cam = try! XCTUnwrap(resolved.webcam)
        XCTAssertEqual(cam.origin, .zero)
        XCTAssertEqual(cam.maxX, resolved.screen.minX, accuracy: 1)
    }

    func test_resolve_splitHorizontal_clampsFractionToValidRange() {
        let tooSmall = LayoutCalculator.resolve(
            preset: LayoutPreset(mode: .splitHorizontal(screenSide: .left, screenFraction: 0.05)),
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertGreaterThanOrEqual(tooSmall.screen.size.width, 1920 * 0.1 - 1)

        let tooLarge = LayoutCalculator.resolve(
            preset: LayoutPreset(mode: .splitHorizontal(screenSide: .left, screenFraction: 1.5)),
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertLessThanOrEqual(tooLarge.screen.size.width, 1920 * 0.9 + 1)
    }

    func test_resolve_solidBackground_insetsScreenByPadding() {
        let preset = LayoutPreset(
            mode: .pip(position: .bottomRight, size: .medium),
            background: .solid(color: RGBColor(r: 0.1, g: 0.2, b: 0.3)),
            padding: 48
        )
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertEqual(resolved.screen.minX, 48)
        XCTAssertEqual(resolved.screen.minY, 48)
        XCTAssertEqual(resolved.screen.size.width, 1920 - 96)
        XCTAssertEqual(resolved.screen.size.height, 1080 - 96)
        if case .solid(let c) = resolved.background {
            XCTAssertEqual(c.x, 0.1, accuracy: 1e-6)
        } else {
            XCTFail("expected solid background")
        }
    }

    func test_resolve_wallpaperBackground_insetsScreenAndResolvesMesh() {
        let preset = LayoutPreset(
            mode: .pip(position: .bottomRight, size: .medium),
            background: .wallpaper(WallpaperGradient(
                name: "Aurora",
                base: RGBColor(r: 0.05, g: 0.06, b: 0.13),
                blobs: [
                    WallpaperGradient.Blob(color: RGBColor(r: 0.2, g: 0.4, b: 0.9, a: 0.9), x: 0.18, y: 0.2, radius: 0.95),
                    WallpaperGradient.Blob(color: RGBColor(r: 0.5, g: 0.2, b: 0.85, a: 0.85), x: 0.82, y: 0.85, radius: 1.0),
                ]
            )),
            padding: 48
        )
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        // Wallpaper is treated like solid/gradient — the screen insets by padding.
        XCTAssertEqual(resolved.screen.minX, 48)
        XCTAssertEqual(resolved.screen.size.width, 1920 - 96)
        if case .mesh(let base, let blobs) = resolved.background {
            XCTAssertEqual(base.x, 0.05, accuracy: 1e-6)
            XCTAssertEqual(blobs.count, 2)
            // Blob geo packs (x, y, radius, _); strength rides in color.w.
            XCTAssertEqual(blobs[0].geo.x, 0.18, accuracy: 1e-6)
            XCTAssertEqual(blobs[0].geo.z, 0.95, accuracy: 1e-6)
            XCTAssertEqual(blobs[0].color.w, 0.9, accuracy: 1e-6)
        } else {
            XCTFail("expected mesh background")
        }
    }

    func test_resolve_systemWallpaperBackground_fallsBackToSolid() {
        let preset = LayoutPreset(
            background: .systemWallpaper(fallback: .black)
        )
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: false
        )
        if case .solid = resolved.background {
        } else {
            XCTFail("expected solid fallback")
        }
    }

    func test_resolve_camShape_propagatesToResolvedLayout() {
        let preset = LayoutPreset(camShape: .circle)
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertEqual(resolved.webcamShape, .circle)
    }

    // MARK: - Custom (free-form) mode

    func test_resolve_custom_mapsNormalizedRectsToPixels() {
        let preset = LayoutPreset(mode: .custom(
            screen: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            webcam: NormalizedRect(x: 0.7, y: 0.6, width: 0.2, height: 0.1125)
        ))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertEqual(resolved.screen.origin, CGPoint(x: 192, y: 108))
        XCTAssertEqual(resolved.screen.size, CGSize(width: 960, height: 540))
        let webcam = try! XCTUnwrap(resolved.webcam)
        XCTAssertEqual(webcam.origin.x, 1344, accuracy: 0.001)
        XCTAssertEqual(webcam.origin.y, 648, accuracy: 0.001)
        XCTAssertEqual(webcam.size.width, 384, accuracy: 0.001)
        XCTAssertEqual(webcam.size.height, 121.5, accuracy: 0.001)
    }

    func test_resolve_custom_webcamOmitted_whenNoWebcam() {
        let preset = LayoutPreset(mode: .custom(
            screen: .full,
            webcam: NormalizedRect(x: 0.7, y: 0.6, width: 0.2, height: 0.1125)
        ))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: false
        )
        XCTAssertNil(resolved.webcam)
    }

    func test_resolve_custom_nilWebcamRect_yieldsNilCam() {
        let preset = LayoutPreset(mode: .custom(screen: .full, webcam: nil))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertNil(resolved.webcam)
    }

    func test_resolve_custom_degenerateRect_clampsToMinSize() {
        let preset = LayoutPreset(mode: .custom(
            screen: NormalizedRect(x: 0, y: 0, width: 0, height: 0),
            webcam: nil
        ))
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: false
        )
        XCTAssertGreaterThanOrEqual(resolved.screen.size.width, 2)
        XCTAssertGreaterThanOrEqual(resolved.screen.size.height, 2)
    }

    func test_resolve_custom_propagatesShapeRadiusAndBackground() {
        let preset = LayoutPreset(
            mode: .custom(screen: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), webcam: nil),
            camShape: .circle,
            background: .solid(color: RGBColor(r: 0.1, g: 0.2, b: 0.3)),
            screenCornerRadius: 24
        )
        let resolved = LayoutCalculator.resolve(
            preset: preset,
            outputSize: CGSize(width: 1920, height: 1080),
            hasWebcam: true
        )
        XCTAssertEqual(resolved.webcamShape, .circle)
        XCTAssertEqual(resolved.screenCornerRadius, 24)
        // Padding is ignored in custom mode — the screen rect is authored directly.
        XCTAssertEqual(resolved.screen.origin, CGPoint(x: 192, y: 108))
        if case .solid = resolved.background {} else { XCTFail("expected solid background") }
    }

    // MARK: - Legacy helpers

    func test_layerRect_geometryHelpers() {
        let r = LayerRect(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 200))
        XCTAssertEqual(r.minX, 10)
        XCTAssertEqual(r.minY, 20)
        XCTAssertEqual(r.maxX, 110)
        XCTAssertEqual(r.maxY, 220)
        XCTAssertEqual(r.midX, 60)
        XCTAssertEqual(r.midY, 120)
    }
}
