import Foundation

/// v6 -> v7 migrator (buttery zoom-follow tuning). v7 adds
/// `fastMotionSensitivity` and `edgeCushion`, widens the useful camera ranges,
/// and changes the default feel to a slower hybrid follow. Projects whose
/// tuning is still exactly the v6 default are upgraded to the new defaults;
/// customized tuning keeps its existing values and only receives the new fields.
public struct Migrator6To7: ProjectMigrator {
    public let fromVersion: Int = 6
    public let toVersion: Int = 7

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var json = json
        guard var tuning = json["tuning"] as? [String: Any] else {
            return json
        }

        if Self.isOldDefault(tuning) {
            json["tuning"] = Self.newDefault()
        } else {
            tuning["fastMotionSensitivity"] = tuning["fastMotionSensitivity"] ?? TuningSettings.default.fastMotionSensitivity
            tuning["edgeCushion"] = tuning["edgeCushion"] ?? TuningSettings.default.edgeCushion
            json["tuning"] = tuning
        }
        return json
    }

    private static func isOldDefault(_ tuning: [String: Any]) -> Bool {
        if tuning["fastMotionSensitivity"] != nil || tuning["edgeCushion"] != nil {
            return false
        }
        let oldDefault: [String: Any] = [
            "cameraTau": 0.35,
            "settle": 0.25,
            "deadzoneFraction": 0.35,
            "maxPanSpeed": 0.9,
            "lookaheadSeconds": 0.04,
            "pathWindowSeconds": 0.35,
            "travelCollapse": 0.7,
            "clickSnapWindow": 0.15,
            "smoothingScope": SmoothingScope.fullRecording.rawValue,
            "shutterAngle": 180.0,
            "blurStrength": 1.0,
            "cursorBlur": 0.6,
            "transitionSoftness": 0.5
        ]
        for (key, expected) in oldDefault {
            guard value(tuning[key], equals: expected) else { return false }
        }
        return true
    }

    private static func newDefault() -> [String: Any] {
        [
            "cameraTau": TuningSettings.default.cameraTau,
            "settle": TuningSettings.default.settle,
            "deadzoneFraction": TuningSettings.default.deadzoneFraction,
            "edgeCushion": TuningSettings.default.edgeCushion,
            "maxPanSpeed": TuningSettings.default.maxPanSpeed,
            "lookaheadSeconds": TuningSettings.default.lookaheadSeconds,
            "pathWindowSeconds": TuningSettings.default.pathWindowSeconds,
            "fastMotionSensitivity": TuningSettings.default.fastMotionSensitivity,
            "travelCollapse": TuningSettings.default.travelCollapse,
            "clickSnapWindow": TuningSettings.default.clickSnapWindow,
            "smoothingScope": TuningSettings.default.smoothingScope.rawValue,
            "shutterAngle": TuningSettings.default.shutterAngle,
            "blurStrength": TuningSettings.default.blurStrength,
            "cursorBlur": TuningSettings.default.cursorBlur,
            "transitionSoftness": TuningSettings.default.transitionSoftness
        ]
    }

    private static func value(_ actual: Any?, equals expected: Any) -> Bool {
        switch expected {
        case let expected as Double:
            guard let actual = numeric(actual) else { return false }
            return abs(actual - expected) < 0.000_001
        case let expected as String:
            return actual as? String == expected
        default:
            return false
        }
    }

    private static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }
}
