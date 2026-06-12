@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import AppKit

// MARK: - CoreAudioTap

/// Per-process system-audio capture via Core Audio Process Tap (macOS 14.4+).
///
/// **Requires macOS 14.4 or later.** The `CATapDescription` API and
/// `AudioHardwareCreateProcessTap` were added in 14.4; older builds must fall
/// back to `SCKitAudioCapture` (whole-system mixdown). Callers should
/// `if #available(macOS 14.4, *)` before constructing one of these.
///
/// **Lifecycle:**
///  1. `start(bundleIDs:)` — resolves bundle IDs to PIDs, creates a stereo
///     mixdown tap of those PIDs, wraps the tap in an aggregate device, then
///     attaches an `AVAudioEngine` input node to the aggregate device.
///  2. PCM buffers stream out via the returned `AsyncStream`.
///  3. `stop()` — destroys the aggregate device + tap + tears down the engine.
///
/// **Why this exists:** SCKit's audio mixdown captures everything — Spotify,
/// Notification Center, the user's other browser tabs. Per-process tap captures
/// only the bundle IDs the user picks (Zoom, Meet, Slack…). v1.0 ships SCKit
/// as default; this is the opt-in upgrade for 14.4+ users.
@available(macOS 14.4, *)
public actor CoreAudioTap {

    // MARK: - State

    private var tapID: AUAudioObjectID = kAudioObjectUnknown
    private var aggregateID: AUAudioObjectID = kAudioObjectUnknown
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init() {}

    // MARK: - Public API

    /// Begin capturing audio from the given bundle IDs. Resolves running
    /// instances of those bundles to PIDs (apps not running at start time are
    /// silently skipped — there's no "wait for app to launch" semantics in v1.0).
    public func start(bundleIDs: [String]) async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        if engine != nil
            || continuation != nil
            || tapID != kAudioObjectUnknown
            || aggregateID != kAudioObjectUnknown {
            await stop()
        }

        let pids = Self.resolvePIDs(for: bundleIDs)
        guard !pids.isEmpty else { throw CoreAudioTapError.noMatchingProcesses }

        // CATapDescription takes Core Audio process-object IDs (AudioObjectID),
        // not Unix PIDs. Translate via kAudioHardwarePropertyTranslatePIDToProcessObject.
        // PIDs that don't map to an audio-producing process are dropped silently.
        let processObjectIDs: [AudioObjectID] = pids.compactMap { Self.processObjectID(forPID: $0) }
        guard !processObjectIDs.isEmpty else { throw CoreAudioTapError.noMatchingProcesses }

        // `stereoMixdownOfProcesses` is the simplest variant — the system picks
        // a sensible left/right pair and downsamples to a stable rate. We stick
        // to the published init only and avoid the optional properties
        // (`muteBehavior`, `isPrivate`) since their availability shape varies
        // across macOS 14.2 → 14.4 → 15.x point releases.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)

        var tap: AUAudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw CoreAudioTapError.tapCreationFailed(osstatus: tapStatus)
        }
        self.tapID = tap

        // Aggregate device wraps the tap so the rest of the audio stack can read it
        // as an ordinary input. Marked private + tap-only.
        let aggregateUID = "dev.kosmonotes.processtap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "KosmoNotes Process Tap",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: try Self.objectUID(for: tap)]
            ],
        ]

        var aggregate: AUAudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggStatus == noErr, aggregate != kAudioObjectUnknown else {
            // Tap is leaked on failure unless we destroy it explicitly.
            AudioHardwareDestroyProcessTap(tap)
            self.tapID = kAudioObjectUnknown
            throw CoreAudioTapError.aggregateCreationFailed(osstatus: aggStatus)
        }
        self.aggregateID = aggregate

        // Attach AVAudioEngine input to the aggregate device. The engine is the
        // simplest path to get PCM buffers out of an arbitrary AudioDeviceID.
        let (asyncStream, cont) = AudioPCMBufferStream.makeStream()
        self.continuation = cont

        let engine = AVAudioEngine()
        // The input node automatically picks up the device set on the audio unit.
        // Setting kAudioOutputUnitProperty_CurrentDevice on the engine's input audio
        // unit binds the engine to our aggregate device.
        guard let inputUnit = engine.inputNode.audioUnit else {
            teardownDevices()
            throw CoreAudioTapError.engineConfigFailed(osstatus: kAudioHardwareUnspecifiedError)
        }
        var deviceID: AUAudioObjectID = aggregate
        let propStatus = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AUAudioObjectID>.size)
        )
        guard propStatus == noErr else {
            cont.finish()
            self.continuation = nil
            teardownDevices()
            throw CoreAudioTapError.engineConfigFailed(osstatus: propStatus)
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, _ in
            cont.yield(buffer)
        }

        do {
            try engine.start()
        } catch {
            cont.finish()
            self.continuation = nil
            teardownDevices()
            throw CoreAudioTapError.engineStartFailed(underlying: error)
        }
        self.engine = engine
        return asyncStream
    }

    /// Stop the engine, drop the tap + aggregate device, finish the stream.
    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
        teardownDevices()
    }

    // MARK: - Private

    private func teardownDevices() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Translate a Unix PID to a Core Audio process object ID via the HAL property
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`. Returns nil when the
    /// process has no audio object (apps that never opened an audio device).
    static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        return (status == noErr && objectID != kAudioObjectUnknown) ? objectID : nil
    }

    /// Resolve bundle IDs to running pids via NSWorkspace.
    static func resolvePIDs(for bundleIDs: [String]) -> [pid_t] {
        let running = NSWorkspace.shared.runningApplications
        var seen = Set<pid_t>()
        var out: [pid_t] = []
        for app in running {
            guard let bid = app.bundleIdentifier, bundleIDs.contains(bid) else { continue }
            if seen.insert(app.processIdentifier).inserted {
                out.append(app.processIdentifier)
            }
        }
        return out
    }

    /// Read the kAudioTapPropertyUID property to get the tap's UID string.
    /// Required by the aggregate-device construction dictionary.
    static func objectUID(for objectID: AUAudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var uid: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else {
            throw CoreAudioTapError.uidLookupFailed(osstatus: status)
        }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - Errors

@available(macOS 14.4, *)
public enum CoreAudioTapError: Error, LocalizedError, Sendable {
    case noMatchingProcesses
    case tapCreationFailed(osstatus: OSStatus)
    case aggregateCreationFailed(osstatus: OSStatus)
    case uidLookupFailed(osstatus: OSStatus)
    case engineConfigFailed(osstatus: OSStatus)
    case engineStartFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .noMatchingProcesses:
            return "None of the configured bundle IDs are currently running."
        case .tapCreationFailed(let s):
            return "AudioHardwareCreateProcessTap failed (\(s)). Grant audio recording permission and retry."
        case .aggregateCreationFailed(let s):
            return "AudioHardwareCreateAggregateDevice failed (\(s))."
        case .uidLookupFailed(let s):
            return "Could not read tap UID (\(s))."
        case .engineConfigFailed(let s):
            return "Could not bind AVAudioEngine to the tap aggregate device (\(s))."
        case .engineStartFailed(let e):
            return "AVAudioEngine start failed: \(e.localizedDescription)"
        }
    }
}
