import XCTest
@testable import PixelbayDesignSystem

// Covers the pure value<->position mapping behind PBSlider's drag/click
// handling. The gesture wiring (onEditingChanged ordering) isn't unit-testable
// in pure SwiftUI, but this locks down the math that click-to-position and the
// rendered thumb position both depend on.
final class PBSliderMappingTests: XCTestCase {
    private let d: CGFloat = 14   // regular thumb diameter

    func test_fraction_endpoints_and_midpoint() {
        XCTAssertEqual(PBSlider.fraction(forValue: 0, in: 0...2), 0, accuracy: 1e-9)
        XCTAssertEqual(PBSlider.fraction(forValue: 2, in: 0...2), 1, accuracy: 1e-9)
        XCTAssertEqual(PBSlider.fraction(forValue: 1, in: 0...2), 0.5, accuracy: 1e-9)
    }

    func test_fraction_clamps_out_of_range() {
        XCTAssertEqual(PBSlider.fraction(forValue: -5, in: 0...2), 0, accuracy: 1e-9)
        XCTAssertEqual(PBSlider.fraction(forValue: 9, in: 0...2), 1, accuracy: 1e-9)
    }

    func test_fraction_nonzero_lowerBound() {
        // speed slider 0.25...4.0
        XCTAssertEqual(PBSlider.fraction(forValue: 0.25, in: 0.25...4.0), 0, accuracy: 1e-9)
        XCTAssertEqual(PBSlider.fraction(forValue: 4.0, in: 0.25...4.0), 1, accuracy: 1e-9)
        XCTAssertEqual(PBSlider.fraction(forValue: 2.125, in: 0.25...4.0), 0.5, accuracy: 1e-9)
    }

    func test_value_at_track_ends_hits_exact_bounds() {
        let w: CGFloat = 200
        // Pointer at the left thumb-centre (d/2) → lowerBound; at right
        // (w - d/2) → upperBound.
        XCTAssertEqual(PBSlider.value(atX: d / 2, width: w, thumbDiameter: d, in: 0...2), 0, accuracy: 1e-6)
        XCTAssertEqual(PBSlider.value(atX: w - d / 2, width: w, thumbDiameter: d, in: 0...2), 2, accuracy: 1e-6)
    }

    func test_value_clamps_beyond_ends() {
        let w: CGFloat = 200
        XCTAssertEqual(PBSlider.value(atX: -50, width: w, thumbDiameter: d, in: 0...2), 0, accuracy: 1e-6)
        XCTAssertEqual(PBSlider.value(atX: 9999, width: w, thumbDiameter: d, in: 0...2), 2, accuracy: 1e-6)
    }

    func test_value_midpoint() {
        let w: CGFloat = 200
        // Centre of the usable track → midpoint value.
        let midX = d / 2 + (w - d) / 2
        XCTAssertEqual(PBSlider.value(atX: midX, width: w, thumbDiameter: d, in: 0...2), 1.0, accuracy: 1e-6)
    }

    func test_value_and_fraction_are_inverses() {
        // Render maps value→thumbX via thumbX = d/2 + fraction*(w-d); the click
        // handler must invert that exactly so a thumb tapped where it sits
        // doesn't jump.
        let w: CGFloat = 320
        let bounds = 0.25...4.0
        for raw in stride(from: 0.0, through: 1.0, by: 0.1) {
            let value = bounds.lowerBound + raw * (bounds.upperBound - bounds.lowerBound)
            let frac = PBSlider.fraction(forValue: value, in: bounds)
            let thumbX = d / 2 + CGFloat(frac) * (w - d)
            let roundTrip = PBSlider.value(atX: thumbX, width: w, thumbDiameter: d, in: bounds)
            XCTAssertEqual(roundTrip, value, accuracy: 1e-6)
        }
    }
}
