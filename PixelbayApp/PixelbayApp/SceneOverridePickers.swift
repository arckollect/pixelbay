import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

// Per-scene source override pickers. Lifted out of SceneRowView so both the
// scene tile (SceneTileView) and any other surface can host the same control.
//
// Each picker is tri-state via a "Use default" tag: when the binding is nil
// the scene inherits the session-wide ScenesGlobalDefaults; an explicit value
// overrides just that field. `SceneSourceOverride.hasAnyOverride` drives the
// "Custom" badge on the tile.

struct SceneOverridePickers: View {
    let catalog: ScenesSourceCatalog
    let defaults: ScenesGlobalDefaults
    @Binding var override: SceneSourceOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            displayPicker
            cameraPicker
            microphonePicker
            systemAudioToggle
        }
    }

    private var displayPicker: some View {
        Picker("Display", selection: displayBinding) {
            Text("Use default")
                .tag(UInt32?.none)
            ForEach(catalog.displays) { display in
                Text(display.localizedName).tag(UInt32?.some(display.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { override.displayID },
            set: { override.displayID = $0 }
        )
    }

    private var cameraPicker: some View {
        Picker("Camera", selection: cameraBinding) {
            Text("Use default").tag(String?.none)
            ForEach(catalog.cameras) { cam in
                Text(cam.localizedName).tag(String?.some(cam.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var cameraBinding: Binding<String?> {
        Binding(
            get: { override.cameraUniqueID },
            set: { override.cameraUniqueID = $0 }
        )
    }

    private var microphonePicker: some View {
        Picker("Microphone", selection: micBinding) {
            Text("Use default").tag(String?.none)
            ForEach(catalog.microphones) { mic in
                Text(mic.localizedName).tag(String?.some(mic.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { override.micUniqueID },
            set: { override.micUniqueID = $0 }
        )
    }

    private var systemAudioToggle: some View {
        // Tri-state toggle: Use default / On / Off. Picker is the simplest
        // SwiftUI control that surfaces the three states inline without a
        // custom view.
        Picker("System audio", selection: sysAudioBinding) {
            Text("Use default").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
        .pickerStyle(.menu)
    }

    private var sysAudioBinding: Binding<Bool?> {
        Binding(
            get: { override.includeSystemAudio },
            set: { override.includeSystemAudio = $0 }
        )
    }
}
