import XCTest
@testable import PixelbayPermissions

final class PermissionCoordinatorTests: XCTestCase {
    func test_initialState_isAllNotDetermined() async {
        let coord = PermissionCoordinator(probe: .denyAll)
        let s = await coord.statuses
        for kind in PermissionKind.allCases {
            XCTAssertEqual(s[kind], .notDetermined, "\(kind) should start as notDetermined")
        }
    }

    func test_refresh_grantedAtLaunch_isGrantedNotRequiresRelaunch() async {
        let coord = PermissionCoordinator(probe: .grantAll)
        let s = await coord.refresh()
        XCTAssertEqual(s[.screenRecording], .granted)
        XCTAssertEqual(s[.camera], .granted)
        XCTAssertEqual(s[.microphone], .granted)
        XCTAssertEqual(s[.accessibility], .granted)
    }

    func test_screenRecording_midSessionGrant_triggersRequiresRelaunch() async {
        // The signature failure mode: macOS reports the permission as granted
        // but SCStream still fails until the process restarts. The coordinator
        // must surface that as a distinct status, not "granted".
        let preflight = MutableState(false)
        let probe = PermissionProbe.testFake(
            screenRecordingPreflight: { preflight.value }
        )
        let coord = PermissionCoordinator(probe: probe)

        var s = await coord.refresh()
        XCTAssertEqual(s[.screenRecording], .notDetermined)

        preflight.value = true

        s = await coord.refresh()
        XCTAssertEqual(
            s[.screenRecording], .requiresRelaunch,
            "false→true preflight transition within a process lifetime must mark requiresRelaunch"
        )

        let coordReports = await coord.anyRequiresRelaunch
        XCTAssertTrue(coordReports)
    }

    func test_screenRecording_grantedBeforeFirstObservation_doesNotRequireRelaunch() async {
        // Mirror image of the previous test: if preflight was already true the
        // first time we look, the user has already relaunched (or never needed
        // to). Don't bother them with a relaunch CTA.
        let coord = PermissionCoordinator(probe: .testFake(
            screenRecordingPreflight: { true }
        ))
        let s = await coord.refresh()
        XCTAssertEqual(s[.screenRecording], .granted)
        let needsRelaunch = await coord.anyRequiresRelaunch
        XCTAssertFalse(needsRelaunch)
    }

    func test_camera_request_pipesProbeResultIntoStatusMap() async {
        let probe = PermissionProbe.testFake(
            cameraStatus: { .notDetermined },
            requestCamera: { .granted }
        )
        let coord = PermissionCoordinator(probe: probe)
        _ = await coord.refresh()
        let pre = await coord.statuses[.camera]
        XCTAssertEqual(pre, .notDetermined)

        let result = await coord.request(.camera)
        XCTAssertEqual(result, .granted)
        let post = await coord.statuses[.camera]
        XCTAssertEqual(post, .granted)
    }

    func test_microphone_userDenies_yieldsDeniedStatus() async {
        let probe = PermissionProbe.testFake(
            microphoneStatus: { .notDetermined },
            requestMicrophone: { .denied }
        )
        let coord = PermissionCoordinator(probe: probe)
        let result = await coord.request(.microphone)
        XCTAssertEqual(result, .denied)
    }

    func test_accessibility_requestInvokesSystemPrompt_notJustSettings() async {
        // Grant must go through AXIsProcessTrustedWithOptions(prompt) so macOS
        // registers THIS binary in the Accessibility list. Opening the pane
        // alone left users toggling stale entries for other builds.
        let prompted = MutableState(false)
        let probe = PermissionProbe.testFake(
            requestAccessibility: { prompted.value = true; return false }
        )
        let coordinator = PermissionCoordinator(probe: probe)
        let status = await coordinator.request(.accessibility)
        XCTAssertTrue(prompted.value, "request(.accessibility) should call the prompting hook")
        XCTAssertEqual(status, .notDetermined, "still untrusted until the user flips the toggle")
    }

    func test_accessibility_trustedFlipsToGrantedOnRefresh() async {
        let trusted = MutableState(false)
        let coord = PermissionCoordinator(probe: .testFake(
            accessibilityTrusted: { trusted.value }
        ))
        var s = await coord.refresh()
        XCTAssertEqual(s[.accessibility], .notDetermined)

        trusted.value = true
        s = await coord.refresh()
        XCTAssertEqual(s[.accessibility], .granted)
    }

    func test_requiredPermissionsSatisfied_tracksScreenRecordingOnly() async {
        // Camera/mic/accessibility are optional in v0.1; only screen recording
        // gates app launch. The coordinator's requiredPermissionsSatisfied
        // helper drives the onboarding scene's "Continue" enabled state.
        let preflight = MutableState(true)
        let coord = PermissionCoordinator(probe: .testFake(
            screenRecordingPreflight: { preflight.value },
            cameraStatus: { .denied },
            microphoneStatus: { .denied },
            accessibilityTrusted: { false }
        ))
        _ = await coord.refresh()
        let satisfied = await coord.requiredPermissionsSatisfied
        XCTAssertTrue(
            satisfied,
            "screen-recording granted at launch should satisfy required permissions even with cam/mic denied"
        )
    }

    func test_requiredPermissionsSatisfied_falseWhenScreenRecordingMissing() async {
        let coord = PermissionCoordinator(probe: .testFake(
            screenRecordingPreflight: { false },
            cameraStatus: { .granted },
            microphoneStatus: { .granted },
            accessibilityTrusted: { true }
        ))
        _ = await coord.refresh()
        let satisfied = await coord.requiredPermissionsSatisfied
        XCTAssertFalse(satisfied)
    }

    func test_refresh_isIdempotent_repeatedCallsProduceSameResult() async {
        let coord = PermissionCoordinator(probe: .grantAll)
        let s1 = await coord.refresh()
        let s2 = await coord.refresh()
        let s3 = await coord.refresh()
        XCTAssertEqual(s1, s2)
        XCTAssertEqual(s2, s3)
    }
}

// MARK: - Test helpers

// Mutable cell for canned probe values that need to flip mid-test (e.g. the
// false→true preflight transition). NSLock-wrapped because the probe closures
// are @Sendable and may be invoked from the actor's executor.
final class MutableState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { self._value = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

extension PermissionProbe {
    // A probe that denies / never-determined every permission. Used as the
    // baseline in tests that don't care about specific values.
    static let denyAll: PermissionProbe = .testFake()

    // A probe where every permission is already granted at first observation.
    static let grantAll: PermissionProbe = .testFake(
        screenRecordingPreflight: { true },
        cameraStatus: { .granted },
        microphoneStatus: { .granted },
        accessibilityTrusted: { true }
    )

    // Builder with sensible defaults that callers can override pointwise. All
    // open*Settings hooks no-op so tests don't try to actually launch System
    // Settings.
    static func testFake(
        screenRecordingPreflight: @escaping @Sendable () -> Bool = { false },
        requestScreenRecording: @escaping @Sendable () -> Bool = { false },
        cameraStatus: @escaping @Sendable () -> PermissionStatus = { .notDetermined },
        requestCamera: @escaping @Sendable () async -> PermissionStatus = { .denied },
        microphoneStatus: @escaping @Sendable () -> PermissionStatus = { .notDetermined },
        requestMicrophone: @escaping @Sendable () async -> PermissionStatus = { .denied },
        accessibilityTrusted: @escaping @Sendable () -> Bool = { false },
        requestAccessibility: @escaping @Sendable () -> Bool = { false }
    ) -> PermissionProbe {
        PermissionProbe(
            screenRecordingPreflight: screenRecordingPreflight,
            requestScreenRecording: requestScreenRecording,
            openScreenRecordingSettings: {},
            cameraStatus: cameraStatus,
            requestCamera: requestCamera,
            openCameraSettings: {},
            microphoneStatus: microphoneStatus,
            requestMicrophone: requestMicrophone,
            openMicrophoneSettings: {},
            accessibilityTrusted: accessibilityTrusted,
            requestAccessibility: requestAccessibility,
            openAccessibilitySettings: {}
        )
    }
}
