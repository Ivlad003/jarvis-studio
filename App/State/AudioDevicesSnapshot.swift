@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let audioSnapLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AudioDevices")

// MARK: - AudioDevicesSnapshot

/// One-shot diagnostic logger for the system's current default audio input /
/// output devices. Drops a single os_log line into Settings → Logs so a "voice
/// didn't record" report carries the device routing context — Bluetooth
/// headsets in HFP profile, USB interfaces, BlackHole loopbacks, etc., are
/// all observable here.
///
/// Implemented as a free function (not a member of RecorderState) because the
/// snapshot itself is stateless and useful from multiple call sites.
@available(macOS 14.0, *)
enum AudioDevicesSnapshot {

    /// Default input device name — typically the mic that AVAudioEngine will
    /// bind to when capture starts. `nil` when no input is available.
    static func defaultInputName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// All available audio input devices, by localized name. Includes virtual
    /// devices (BlackHole, Loopback, etc.) — useful when diagnosing which
    /// device the user has wired as system audio source.
    static func allInputs() -> [String] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map(\.localizedName)
    }

    /// Default output device name (where speakers / headphones currently route).
    /// macOS doesn't expose this through AVCaptureDevice — we fall back to the
    /// Core Audio HAL.
    static func defaultOutputName() -> String? {
        defaultDeviceName(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// True when the default output is the built-in speaker route.
    static func defaultOutputIsBuiltIn() -> Bool {
        guard let deviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
            return false
        }
        return transportType(of: deviceID) == kAudioDeviceTransportTypeBuiltIn
    }

    /// Default input device name via Core Audio HAL — useful as a cross-check
    /// against `AVCaptureDevice.default(for: .audio)` when the two disagree
    /// (rare, but happens when an app overrides input via AVAudioEngine).
    static func defaultInputNameHAL() -> String? {
        defaultDeviceName(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Emit a one-line summary covering input + output + the full input device
    /// catalogue. Stays short enough to be readable in the Logs tab.
    static func log(context: String) {
        let input = defaultInputName() ?? "(none)"
        let inputHAL = defaultInputNameHAL() ?? "(none)"
        let output = defaultOutputName() ?? "(none)"
        let inputs = allInputs().joined(separator: ", ")
        audioSnapLog.info("audio devices [\(context, privacy: .public)]: defaultInput=\"\(input, privacy: .public)\" defaultInputHAL=\"\(inputHAL, privacy: .public)\" defaultOutput=\"\(output, privacy: .public)\" allInputs=[\(inputs, privacy: .public)]")
    }

    // MARK: - HAL helpers

    private static func defaultDeviceName(selector: AudioObjectPropertySelector) -> String? {
        guard let deviceID = defaultDeviceID(selector: selector) else { return nil }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard nameStatus == noErr else { return nil }
        return name as String
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size,
            &deviceID
        )
        guard getStatus == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return 0 }
        return transport
    }
}
