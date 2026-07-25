import Foundation

// AI CONTEXT — Pure route-loss policy shared by PlaybackEngine and headless
// regression tests. AVAudioSession may deliver oldDeviceUnavailable before
// currentRoute has settled, leaving the removed AirPods temporarily visible as
// both previous and current output. The same identifier is never proof of a
// replacement route; keep the pending pause until a genuinely different
// non-built-in output arrives.
public enum AudioRouteLossPolicy {
    public static func replacementOutputIsConfirmed(
        currentOutputIdentifier: String?,
        previousOutputIdentifier: String?,
        currentOutputIsBuiltIn: Bool,
        explicitNewDeviceSignal: Bool = false
    ) -> Bool {
        guard !currentOutputIsBuiltIn,
              let currentOutputIdentifier,
              !currentOutputIdentifier.isEmpty else {
            return false
        }
        if explicitNewDeviceSignal {
            return true
        }
        guard let previousOutputIdentifier else { return false }
        return currentOutputIdentifier != previousOutputIdentifier
    }
}
