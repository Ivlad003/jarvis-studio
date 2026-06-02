@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

// MARK: - Core Audio HAL helpers (private, file-scope)
//
// Used by `AudioEngine.start` to detect when the system's default input is a
// Bluetooth mic (AirPods Max, Beats, headsets — they show up at 16/24 kHz in
// HFP/SCO mode) and substitute the built-in mic instead. Two independent
// gains:
//   1. Avoids the 4–6 s SCO link negotiation that delays first PCM buffer.
//   2. Keeps macOS in A2DP for output so playback through the same Bluetooth
//      device stays at 48 kHz (no "slow-bassy" artifact).
//
// The user's system audio routing is NOT mutated — we only re-bind our own
// `AVAudioEngine.inputNode` to a specific device via AUHAL setDeviceID, so
// other apps and the system itself still see the user's chosen default.

/// Returns the system's current default-input AudioDeviceID, or nil if the
/// HAL has no default input bound (rare — usually means no mic at all).
private func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    return status == noErr && deviceID != 0 ? deviceID : nil
}

/// `kAudioDevicePropertyTransportType` for the given device, or 0 on error.
private func transportType(of deviceID: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    return transport
}

/// True when the device's transport type is Bluetooth (classic or LE).
/// Bluetooth-over-USB or Bluetooth-via-aggregate devices return false here —
/// they're rare enough that the false negative is acceptable.
private func isBluetoothTransport(_ deviceID: AudioDeviceID) -> Bool {
    let t = transportType(of: deviceID)
    return t == kAudioDeviceTransportTypeBluetooth
        || t == kAudioDeviceTransportTypeBluetoothLE
}

/// Set the system's default input device. Returns true on success.
/// Used to temporarily swap away from a Bluetooth mic during recording so
/// `AVAudioEngine` doesn't get bound to a HFP/SCO sub-device of the
/// `CADefaultDeviceAggregate` that macOS auto-creates with AirPods+other
/// inputs present. Restored on `stop()`.
@discardableResult
private func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var newID = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &newID
    )
    return status == noErr
}

/// Find the macOS built-in microphone's AudioDeviceID by scanning all input
/// devices and returning the first with `kAudioDeviceTransportTypeBuiltIn`.
/// Returns nil on Macs with no built-in mic (rare — Mac mini etc. with
/// external-only setup).
private func findBuiltInMicrophoneDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
    ) == noErr else { return nil }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return nil }
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
    ) == noErr else { return nil }

    for deviceID in deviceIDs {
        // Skip devices without an input stream.
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &inputSize) == noErr,
              inputSize > 0 else { continue }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(inputSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        let typedBufferList = bufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &inputAddr, 0, nil, &inputSize, typedBufferList) == noErr else { continue }
        let totalChannels = UnsafeMutableAudioBufferListPointer(typedBufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
        if totalChannels == 0 { continue }

        if transportType(of: deviceID) == kAudioDeviceTransportTypeBuiltIn {
            return deviceID
        }
    }
    return nil
}

// MARK: - AudioEngine

/// Unified-log channel for capture-engine diagnostics. Filterable via
/// `log show --predicate 'subsystem == "dev.kosmonotes.studio"' --info` or in
/// Console.app. Emits at .info for routine state changes and .error for the
/// silent-failure modes (degenerate input format, zero buffers in N seconds).
private let audioEngineLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AudioEngine")

/// Real-time-thread-safe counter incremented by the tap closure. The actor
/// can't be touched from the audio render thread, so the closure increments
/// this `NSLock`-guarded counter directly and the actor polls it.
private final class TapBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0
    private var _totalFrames: Int = 0

    func increment(frames: Int) {
        lock.lock()
        _count += 1
        _totalFrames += frames
        lock.unlock()
    }

    var snapshot: (count: Int, totalFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_count, _totalFrames)
    }
}

/// Real-time-safe mute flag. Read inside the tap closure (runs on the audio
/// render thread) to decide whether to silence incoming PCM buffers; written
/// from the actor (or any thread, really) when the user toggles mute.
/// `NSLock` here is sub-microsecond and the tap callback runs at ~10 Hz, so
/// contention is non-existent.
final class TapMuteFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _muted: Bool = false

    var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _muted
    }

    func setMuted(_ muted: Bool) {
        lock.lock(); _muted = muted; lock.unlock()
    }
}

// MARK: - AudioEngine

/// Captures microphone input via AVAudioEngine.
///
/// Delivers ~100 ms buffers of mono Float32 PCM at 48 kHz via an AsyncStream.
/// Safe to use from Swift concurrency contexts — all mutable state is actor-isolated.
public actor AudioEngine {

    // MARK: Public types

    public struct Config: Sendable {
        public let sampleRate: Double
        public let channels: AVAudioChannelCount

        public init(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) {
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    enum TapBootstrapStrategy: Equatable {
        case installBeforeEngineStart
        case installAfterEngineStart
    }

    enum TapInstallFormatStrategy: Equatable {
        case keepProposedFormat
        case refreshFromLiveAUHALFormat
    }

    nonisolated static func tapBootstrapStrategy(
        preStartSampleRate: Double,
        preStartChannelCount: AVAudioChannelCount
    ) -> TapBootstrapStrategy {
        if preStartSampleRate > 0, preStartChannelCount > 0 {
            return .installBeforeEngineStart
        }
        return .installAfterEngineStart
    }

    nonisolated static func tapInstallFormatStrategy(
        proposedSampleRate: Double,
        proposedChannelCount: AVAudioChannelCount,
        liveSampleRate: Double,
        liveChannelCount: AVAudioChannelCount
    ) -> TapInstallFormatStrategy {
        guard liveSampleRate > 0, liveChannelCount > 0 else {
            return .keepProposedFormat
        }
        if proposedSampleRate != liveSampleRate || proposedChannelCount != liveChannelCount {
            return .refreshFromLiveAUHALFormat
        }
        return .keepProposedFormat
    }

    nonisolated static func overwriteWithSilence(_ buffer: AVAudioPCMBuffer) {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
    }

    // MARK: Private state

    private let config: Config
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    /// Shared with the tap closure. Flip this to silence mic samples mid-recording
    /// (live mute) without tearing down the engine — the tap closure reads it
    /// every callback and overwrites PCM with silence when true. The audio file
    /// keeps growing during mute, so timestamps stay aligned.
    private let muteFlag = TapMuteFlag()
    /// Target output format the rest of the pipeline expects (e.g. 48 kHz
    /// mono Float32). Stored so a route-change-triggered tap reinstall can
    /// reuse the same target without rebuilding from `config`.
    private var targetFormat: AVAudioFormat?
    /// Per-format AVAudioConverter cache. Kept across tap reinstalls so a
    /// route swap (built-in mic → AirPods) only pays the converter-build
    /// cost once per source format the user encounters in this session.
    private var converterCache: ConverterCache?
    /// Counter that the tap closure increments on every callback. Used by
    /// the no-buffer-arrived watchdog and propagated across reinstalls.
    private var bufferCounter: TapBufferCounter?
    /// Token from `NotificationCenter.addObserver(forName:.AVAudioEngineConfigurationChange,...)`.
    /// Removed in `stop()` to avoid leaking observers between recordings.
    private var configChangeObserver: NSObjectProtocol?
    /// When we temporarily swap the system's default input device away from
    /// a Bluetooth mic, this stores the user's original choice so `stop()`
    /// can restore it. nil when no swap was performed.
    private var savedDefaultInputDevice: AudioDeviceID?

    /// Buffer-flow supervisor. Watches `bufferCounter` on a 1 s cadence after
    /// the first buffer has arrived; if no new buffers land for ~3 ticks
    /// while the engine is supposed to be live and not muted, proactively
    /// triggers `recreateEngineAfterRouteChange()`. This is the safety net
    /// for HAL drift scenarios that don't fire `AVAudioEngineConfigurationChange`
    /// at all — e.g. SCStream coming online while the mic is already armed,
    /// AirPods silently dropping their SCO link, an aggregate device being
    /// dissolved by the OS mid-recording. Without this, the engine could
    /// stay dead silently for the rest of the session (the 37-minute "audio
    /// disappeared from the start" failure mode reported by users).
    private var supervisorTask: Task<Void, Never>?
    private var supervisorLastCount: Int = 0
    private var supervisorStalledTicks: Int = 0
    /// How many consecutive 1 s ticks of zero buffer growth count as a stall.
    /// 3 s is well above the 100 ms tap callback cadence (we'd expect ~10
    /// buffers/sec), but short enough to recover before the user notices.
    private let supervisorStallThreshold: Int = 3

    // MARK: Init

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Public API

    /// Start mic capture. Returns an AsyncStream of PCM buffers (~100 ms / 4800 frames each).
    /// Throws if the audio engine cannot start (e.g. no input device, or no buffers
    /// arrive within 3 s of the tap being installed — the silent-TCC failure mode).
    public func start() async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        // Stop any existing session
        if engine != nil {
            await stop()
        }

        audioEngineLog.info("AudioEngine.start: requested sampleRate=\(self.config.sampleRate, privacy: .public) channels=\(self.config.channels, privacy: .public)")

        // Swap system default input from Bluetooth to built-in mic BEFORE
        // creating AVAudioEngine. Doing this AFTER engine.start fires an
        // AVAudioEngineConfigurationChange notification ~1 s later, and
        // attempting to engine.start() inside that handler returns
        // `-10868 kAudioUnitErr_FormatNotSupported` because the format we
        // configured the engine with no longer matches the new device.
        // Pre-engine swap + 1 s propagation delay lets the new default
        // settle in the HAL, then the engine bootstraps cleanly with the
        // built-in mic from scratch — no mid-flight reconfiguration.
        swapDefaultInputToBuiltInIfBluetooth(context: "start")
        if savedDefaultInputDevice != nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let engine = AVAudioEngine()
        self.engine = engine

        // Desired output format the rest of the pipeline expects.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: config.channels,
            interleaved: false
        ) else {
            audioEngineLog.error("AudioEngine.start: failed to build target AVAudioFormat")
            throw AudioEngineError.formatCreationFailed
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation

        // Touch inputNode BEFORE prepare/start so AVAudioEngine instantiates
        // its underlying AUHAL — otherwise engine.start() throws an
        // "inputNode != nullptr || outputNode != nullptr" assertion because
        // no nodes are in use yet. Just reading the property is enough.
        let inputNode = engine.inputNode

        // NOTE: setVoiceProcessingEnabled(true) (Apple's AEC + AGC + NS) was
        // tried here as a fix for the speaker → mic echo loop you get when
        // recording mic + system audio without headphones. It works, but it
        // forces VoiceProcessingIO into mono 16 kHz with aggressive AGC that
        // dropped mic gain to inaudible levels and broke our 48 kHz capture
        // pipeline. Rolled back; the recommended workaround for echo is
        // headphones (zero code, perfect cancellation).

        // (BT swap already happened above, before AVAudioEngine() — no need
        // to re-swap here; the engine has been created on top of the new
        // default and the AUHAL is bound to built-in mic.)

        // Stash everything the tap closure needs as actor state so a later
        // route-change-triggered reinstall can rebuild the tap without losing
        // the AsyncStream consumer downstream.
        self.targetFormat = targetFormat
        let converterCache = ConverterCache()
        self.converterCache = converterCache
        let counter = TapBufferCounter()
        self.bufferCounter = counter

        let preStartInputFormat = inputNode.outputFormat(forBus: 0)
        let bootstrapStrategy = Self.tapBootstrapStrategy(
            preStartSampleRate: preStartInputFormat.sampleRate,
            preStartChannelCount: preStartInputFormat.channelCount
        )
        if bootstrapStrategy == .installBeforeEngineStart {
            audioEngineLog.info("AudioEngine.start: pre-start input format already usable — sampleRate=\(preStartInputFormat.sampleRate, privacy: .public) channels=\(preStartInputFormat.channelCount, privacy: .public). Installing tap before engine.start().")
            installTap(on: inputNode, inputFormat: preStartInputFormat)
        }

        // Most Macs produce a usable input format before start; in that common
        // case we arm the tap first, matching the stable patterns used by the
        // dictation pipeline and CoreAudioTap. Some fresh-TCC / ad-hoc-signed
        // builds still report a degenerate 0-channel/0-Hz format here; only
        // those fall back to the delayed-install path below.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            audioEngineLog.error("AudioEngine.start: engine.start() threw — \(error.localizedDescription, privacy: .public)")
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            self.targetFormat = nil
            self.converterCache = nil
            self.bufferCounter = nil
            restoreDefaultInputDeviceIfSwapped()
            throw AudioEngineError.engineStartFailed(underlying: error)
        }

        // Poll for the input bus format to stabilize. After mic-permission
        // grant the AUHAL typically needs 1–3 polls to bind. Polling at 10 ms
        // (was 50 ms) shaves the worst-case "first words eaten" window from
        // ~150 ms down to ~30 ms while keeping the same 1 s ceiling
        // (now 100 attempts × 10 ms instead of 20 × 50 ms).
        //
        // IMPORTANT: query the AUHAL directly via `auAudioUnit.outputBusses[0]
        // .format` rather than `inputNode.outputFormat(forBus: 0)`. The
        // AVAudioEngine-level wrapper caches the bus format from the LAST
        // hardware binding — after a `setDeviceID` swap (BT → built-in mic),
        // the cached value can be stale by one device cycle, returning the
        // BT 24 kHz format while the AUHAL actually reads the built-in mic
        // at 48 kHz. Installing a tap with the stale format triggers a
        // hard `format.sampleRate == inputHWFormat.sampleRate` assertion in
        // AVAudioEngineGraph.mm:2031 and SIGABRTs the process. Querying the
        // AUHAL bus is the authoritative source.
        var inputFormat = inputNode.auAudioUnit.outputBusses[0].format
        var attempts = 0
        if bootstrapStrategy == .installAfterEngineStart {
            audioEngineLog.info("AudioEngine.start: pre-start input format was degenerate — delaying tap install until AUHAL binds after engine.start().")
            while (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) && attempts < 100 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                inputFormat = inputNode.auAudioUnit.outputBusses[0].format
                attempts += 1
            }
        }
        audioEngineLog.info("AudioEngine.start: engine running, input format after \(attempts, privacy: .public) polls — sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")

        // If still degenerate after 1 s, mic isn't routed. Fail clearly
        // instead of silently writing 0-byte segments.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            audioEngineLog.error("AudioEngine.start: input format never bound (channels=0 or sampleRate=0 after 1 s)")
            engine.stop()
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            self.targetFormat = nil
            self.converterCache = nil
            self.bufferCounter = nil
            restoreDefaultInputDeviceIfSwapped()
            throw AudioEngineError.engineStartFailed(underlying: NSError(
                domain: "AudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Default input device did not bind within 1 s. Microphone permission may be denied or no input device is available."]
            ))
        }

        // Bluetooth HFP/SCO detection: AirPods, Beats, and most BT headsets
        // expose their mic at 16/24 kHz mono when system audio is routed
        // through them. Apple's audio HAL takes noticeably longer to fully
        // wire up an SCO mic — first PCM buffer can arrive 4–6 s after the
        // tap is installed. Bump the no-buffer deadline to compensate.
        let isLikelyBluetoothMic = inputFormat.sampleRate <= 24_000.0 && inputFormat.channelCount == 1
        if isLikelyBluetoothMic {
            audioEngineLog.info("AudioEngine.start: input rate \(inputFormat.sampleRate, privacy: .public) Hz mono looks like Bluetooth HFP/SCO (e.g. AirPods Max). Extending no-buffer deadline; this also degrades playback quality system-wide while active.")
        }

        if bootstrapStrategy == .installAfterEngineStart {
            // Install the tap with the validated input format. See `installTap`
            // for the closure body (real-time-safe, silences on mute, converts to
            // targetFormat when the bound device's native format differs).
            installTap(on: inputNode, inputFormat: inputFormat)
            audioEngineLog.info("AudioEngine.start: tap installed after engine.start, awaiting first buffer")
        } else {
            audioEngineLog.info("AudioEngine.start: tap armed before engine.start, awaiting first buffer")
        }

        // Subscribe to AVAudioEngineConfigurationChange. AVAudioEngine fires
        // this on route swap (BT pair/unpair, headphone (un)plug, sample-rate
        // change) AND auto-stops itself per Apple docs — without a handler
        // the tap goes dead and the user gets either zero buffers (recording
        // freezes) or wrong-rate buffers (the "slow bassy" playback artifact
        // we hit while debugging this). The handler restarts + reinstalls the
        // tap so the AsyncStream stays continuous from SegmentWriter's POV.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleConfigurationChange()
            }
        }
        self.configChangeObserver = observer

        // Wait for the tap callback to actually fire. If it doesn't, either:
        // (a) Bluetooth SCO is still negotiating — common with AirPods Max as
        //     the default input; SCO link can take 4–6 s to deliver first PCM.
        // (b) TCC trust is stale on an ad-hoc-signed dev build — HAL reports
        //     permission granted but never routes audio to this process.
        // 8 s deadline accommodates (a); message guides the user toward the
        // right fix based on the bound input format we just observed.
        // Uniform 8 s deadline for both BT and non-BT paths. On flaky
        // Mac+macOS combos with aggregate-device interference, even the
        // built-in mic can take 4–6 s to deliver its first buffer after
        // a CADefaultDeviceAggregate swap. 8 s covers both BT SCO setup
        // and non-BT HAL warmup; a real TCC denial still surfaces clearly
        // because permission failures fail fast (engine.start throws or
        // input format never binds at the 1 s ceiling above).
        let waitDeadlineSeconds: TimeInterval = 8.0
        let deadline = Date().addingTimeInterval(waitDeadlineSeconds)
        while counter.snapshot.count == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let snap = counter.snapshot
        if snap.count == 0 {
            let waited = Int(waitDeadlineSeconds)
            audioEngineLog.error("AudioEngine.start: tap callback did not fire within \(waited, privacy: .public) s. Bound input rate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public). Likely cause: \(isLikelyBluetoothMic ? "Bluetooth HFP/SCO mic still negotiating, or BT link dropped" : "TCC trust stale (ad-hoc-signed build)", privacy: .public).")
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            restoreDefaultInputDeviceIfSwapped()
            let message: String
            if isLikelyBluetoothMic {
                message = "Microphone tap installed but no audio arrived in \(waited) s. Bound input is Bluetooth HFP/SCO at \(Int(inputFormat.sampleRate)) Hz — most likely AirPods/Beats/headset. Workarounds: (1) System Settings → Sound → Input → switch to MacBook Pro Microphone (recommended — also avoids the slow/bassy playback artifact while recording), (2) re-pair the Bluetooth device, (3) try again — SCO can take a few seconds to wake."
            } else {
                message = "Microphone tap installed but no audio arrived in \(waited) s. macOS reports permission as granted, but the audio HAL isn't delivering data. Run `tccutil reset Microphone dev.kosmonotes.studio`, relaunch the app, and grant the prompt again."
            }
            throw AudioEngineError.engineStartFailed(underlying: NSError(
                domain: "AudioEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
        audioEngineLog.info("AudioEngine.start: first buffers received — count=\(snap.count, privacy: .public) totalFrames=\(snap.totalFrames, privacy: .public)")

        // Arm the buffer-flow supervisor now that we've observed at least one
        // buffer. Any subsequent stall (3 s of no growth) triggers recreate.
        startSupervisor()

        return stream
    }

    /// Live-toggle mic mute. When true, the tap callback overwrites each PCM
    /// buffer with silence before yielding it, so the segment writer timeline
    /// keeps growing but the user's voice goes nowhere.
    /// The engine itself stays running — toggling back to false resumes
    /// capture instantly without re-arming permissions / re-binding AUHAL.
    public func setMuted(_ muted: Bool) {
        muteFlag.setMuted(muted)
    }

    /// Snapshot of the current mute state. Useful for UI sync after a
    /// pause/resume that may have lost client-side state.
    public var isMuted: Bool {
        muteFlag.isMuted
    }

    /// Stop mic capture, remove tap, finish the stream.
    public func stop() async {
        // Cancel the supervisor FIRST so its next tick can't race with the
        // teardown sequence below (e.g. invoke recreate while engine is being
        // torn down, leaving a dangling AVAudioEngine after stop returns).
        stopSupervisor()
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
        engine = nil
        continuation = nil
        targetFormat = nil
        converterCache = nil
        bufferCounter = nil
        // Restore user's original system default input if we swapped it
        // away from a Bluetooth device for this recording.
        restoreDefaultInputDeviceIfSwapped()
    }

    // MARK: - Bluetooth mic auto-substitution (private)

    /// When the system's default input is a Bluetooth device (AirPods/Beats/
    /// headset), temporarily swap the SYSTEM default input to the built-in
    /// microphone for the duration of our recording.
    ///
    /// Why this is system-wide and not just per-engine:
    /// `AVAudioEngine.inputNode.auAudioUnit.setDeviceID(builtIn)` succeeds in
    /// API call but doesn't actually re-route inside AUHAL when macOS has
    /// auto-created a `CADefaultDeviceAggregate` device (which it does
    /// whenever AirPods + other inputs are simultaneously available — visible
    /// in our `AudioDevices` snapshot logs). The aggregate's bus 0 stays
    /// pinned to the AirPods sub-device; our `setDeviceID` is a no-op.
    /// The only reliable workaround is to dissolve the aggregate by changing
    /// the system default input — once built-in mic is the default, AUHAL
    /// binds to it directly at 48 kHz with no SCO negotiation.
    ///
    /// Trade-offs:
    ///   - Other apps recording at the same moment briefly see the input
    ///     switch (Zoom/Discord/etc.). Restored on `stop()`.
    ///   - System Settings → Sound → Input pane visibly toggles for the
    ///     duration of the recording.
    ///   - Recording from AirPods mic intentionally (e.g. far from laptop)
    ///     becomes impossible without a per-user Settings toggle. Future
    ///     work; default is "just works" for the 95% case.
    ///
    /// Called from `start` BEFORE creating the AVAudioEngine, so the engine
    /// bootstraps on top of the new default and avoids the mid-flight
    /// reconfiguration storm that errors -10868 inside handleConfigChange.
    private func swapDefaultInputToBuiltInIfBluetooth(context: String) {
        guard let defaultInput = defaultInputDeviceID(),
              isBluetoothTransport(defaultInput)
        else { return }
        guard let builtIn = findBuiltInMicrophoneDeviceID() else {
            audioEngineLog.info("AudioEngine.\(context, privacy: .public): default input is Bluetooth but built-in mic not found on this Mac. Continuing with BT input; SCO timeout will apply.")
            return
        }
        // Save the current default so stop() can restore it. Only save on
        // the FIRST swap of this recording.
        if savedDefaultInputDevice == nil {
            savedDefaultInputDevice = defaultInput
        }
        if setDefaultInputDevice(builtIn) {
            audioEngineLog.info("AudioEngine.\(context, privacy: .public): default input was Bluetooth (deviceID=\(defaultInput, privacy: .public)). Swapped system default to built-in mic (deviceID=\(builtIn, privacy: .public)) to dissolve aggregate device and skip SCO setup delay. Will restore on stop().")
        } else {
            audioEngineLog.error("AudioEngine.\(context, privacy: .public): AudioObjectSetPropertyData(DefaultInputDevice) failed. Falling back to system default (BT); SCO timeout will apply.")
            savedDefaultInputDevice = nil
        }
    }

    /// Restore the system's default input device to whatever the user had
    /// before we started recording. No-op if no swap happened.
    private func restoreDefaultInputDeviceIfSwapped() {
        guard let original = savedDefaultInputDevice else { return }
        if setDefaultInputDevice(original) {
            audioEngineLog.info("AudioEngine.stop: restored system default input to user's original choice (deviceID=\(original, privacy: .public)).")
        } else {
            audioEngineLog.error("AudioEngine.stop: failed to restore system default input to deviceID=\(original, privacy: .public). User may need to re-pick in System Settings → Sound → Input.")
        }
        savedDefaultInputDevice = nil
    }

    // MARK: - Tap installation (private)

    /// Install (or reinstall) the audio tap on `inputNode`, wiring its
    /// callback to the actor's stored `continuation`, `targetFormat`,
    /// `converterCache`, and `bufferCounter`. The closure runs on the audio
    /// render thread — real-time-safe: no actor hops, no allocations beyond
    /// the converted PCM buffer, `os.Logger` is lock-free at `.debug`.
    private func installTap(on inputNode: AVAudioInputNode, inputFormat: AVAudioFormat) {
        guard let targetFormat = self.targetFormat,
              let converterCache = self.converterCache,
              let counter = self.bufferCounter,
              let cont = self.continuation else {
            audioEngineLog.error("AudioEngine.installTap: missing actor state — skipping. This usually means the engine was torn down between start() and a configuration-change reinstall.")
            return
        }
        // Defensive: remove any stale tap before installing. AVAudioEngine
        // throws an `Exception 'Format mismatch'` if you call installTap
        // twice without a removeTap in between.
        inputNode.removeTap(onBus: 0)

        let bufferSize: AVAudioFrameCount = 4800
        let mute = muteFlag
        let liveInputFormat = inputNode.auAudioUnit.outputBusses[0].format
        let tapInputFormat: AVAudioFormat
        switch Self.tapInstallFormatStrategy(
            proposedSampleRate: inputFormat.sampleRate,
            proposedChannelCount: inputFormat.channelCount,
            liveSampleRate: liveInputFormat.sampleRate,
            liveChannelCount: liveInputFormat.channelCount
        ) {
        case .keepProposedFormat:
            tapInputFormat = inputFormat
        case .refreshFromLiveAUHALFormat:
            tapInputFormat = liveInputFormat
            audioEngineLog.info("AudioEngine.installTap: refreshing stale tap format from proposed sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) to live AUHAL sampleRate=\(liveInputFormat.sampleRate, privacy: .public) channels=\(liveInputFormat.channelCount, privacy: .public)")
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapInputFormat) { buffer, _ in
            // Live mic-mute: keep yielding the same frame count as silence so
            // downstream audio timestamps stay aligned with screen/video.
            counter.increment(frames: Int(buffer.frameLength))
            if mute.isMuted {
                AudioEngine.overwriteWithSilence(buffer)
            }
            let bufferFormat = buffer.format
            if bufferFormat.sampleRate == targetFormat.sampleRate
                && bufferFormat.channelCount == targetFormat.channelCount
                && bufferFormat.commonFormat == targetFormat.commonFormat {
                cont.yield(buffer)
                return
            }
            guard let converter = converterCache.converter(from: bufferFormat, to: targetFormat) else {
                audioEngineLog.error("AudioEngine.tap: converter creation failed")
                return
            }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / bufferFormat.sampleRate
            ) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, frameCapacity)) else {
                return
            }
            var error: NSError?
            let src = buffer
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return src
            }
            if status != .error, converted.frameLength > 0 {
                cont.yield(converted)
            }
        }
    }

    // MARK: - Route change handling (private)

    /// Called from the `AVAudioEngineConfigurationChange` observer when the
    /// system swaps the active input/output device or changes its format.
    ///
    /// AVAudioEngine has already auto-stopped itself by the time this fires
    /// (per Apple docs). We restart it, wait for the new input format to
    /// bind, and reinstall the tap so the upstream AsyncStream keeps
    /// receiving buffers — converted to our `targetFormat` (e.g. 48 kHz mono
    /// Float32) regardless of what the new device's native rate is.
    ///
    /// On failure we log and bail; the next user-initiated stop()/start()
    /// will recover. We deliberately do NOT throw or finish() the stream —
    /// the recording is still notionally alive and forcibly killing it would
    /// surprise the user mid-session.
    private func handleConfigurationChange() async {
        guard let engine = self.engine else {
            audioEngineLog.info("AudioEngine.handleConfigurationChange: notification fired after stop() — ignoring")
            return
        }
        audioEngineLog.info("AudioEngine.handleConfigurationChange: AVAudioEngineConfigurationChange fired (route swap, headphone connect/disconnect, or sample-rate change). Restarting engine.")

        let inputNode = engine.inputNode
        // Reset counter so the no-buffer watchdog (if any caller adds one) sees
        // a clean slate after the swap.
        bufferCounter = TapBufferCounter()
        // Keep the buffer-flow supervisor's baseline in sync with the freshly
        // reset counter; otherwise its next tick sees `current < lastCount`
        // and treats the natural reset as "no progress".
        resetSupervisorBaseline()

        // CRITICAL: poll AUHAL for the new input format BEFORE engine.start().
        // After a route swap (SCStream startup for screen-record, headphones
        // (dis)connect, sample-rate change) the AUHAL goes transient — bus 0
        // briefly reports channels=0 / sampleRate=0 while it rebinds to the
        // new device. Calling engine.start() in that window returns
        // `-10868 kAudioUnitErr_FormatNotSupported`, and after a single
        // failure AVAudioEngine refuses to restart for the rest of the
        // recording. Logs show this dying silently for 36 minutes at a time
        // (mic watchdog: level near zero for 2176s) — that's the
        // "Audio + Screen mode records system audio but mic stays empty"
        // user bug. Waiting up to 1 s for the AUHAL to settle, then retrying
        // start() on backoff, restores the mic without a full engine rebuild.
        var inputFormat = inputNode.auAudioUnit.outputBusses[0].format
        var preStartAttempts = 0
        while (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) && preStartAttempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            inputFormat = inputNode.auAudioUnit.outputBusses[0].format
            preStartAttempts += 1
        }
        audioEngineLog.info("AudioEngine.handleConfigurationChange: pre-start AUHAL settle — sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) polls=\(preStartAttempts, privacy: .public)")

        // We don't re-swap the system default here — we already did that in
        // start() before the engine was created, and savedDefaultInputDevice
        // remembers the user's pre-recording choice. Re-swapping mid-handler
        // would fire ANOTHER configuration change in 1 s and put us in a
        // restart loop. The system default is already on built-in for the
        // duration of this recording.

        engine.prepare()
        var lastStartError: Error?
        for attempt in 1...3 {
            do {
                try engine.start()
                lastStartError = nil
                break
            } catch {
                lastStartError = error
                audioEngineLog.error("AudioEngine.handleConfigurationChange: engine.start attempt \(attempt, privacy: .public)/3 failed — \(error.localizedDescription, privacy: .public)")
                // -10868 typically clears within 200–500 ms once the AUHAL
                // finishes binding to the new device. Back off then re-poll
                // the bus format so the next start sees a stable hardware
                // descriptor.
                try? await Task.sleep(nanoseconds: 400_000_000)
                inputFormat = inputNode.auAudioUnit.outputBusses[0].format
            }
        }

        if lastStartError != nil {
            audioEngineLog.error("AudioEngine.handleConfigurationChange: engine.start failed 3× — recreating AVAudioEngine from scratch")
            let recreated = await recreateEngineAfterRouteChange()
            if recreated {
                audioEngineLog.info("AudioEngine.handleConfigurationChange: engine recreated successfully — mic resumed on new instance")
            } else {
                audioEngineLog.error("AudioEngine.handleConfigurationChange: recreate failed — mic will stay silent until user stops/restarts the recording")
            }
            return
        }

        // Engine restarted on the original instance. Final format check —
        // route swaps can flutter, so re-poll after start to make sure the
        // bus didn't go transient again on us.
        let postStartFormat = inputNode.auAudioUnit.outputBusses[0].format
        if postStartFormat.channelCount > 0, postStartFormat.sampleRate > 0 {
            if postStartFormat.sampleRate != inputFormat.sampleRate || postStartFormat.channelCount != inputFormat.channelCount {
                audioEngineLog.info("AudioEngine.handleConfigurationChange: input format changed across engine.start from sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) to sampleRate=\(postStartFormat.sampleRate, privacy: .public) channels=\(postStartFormat.channelCount, privacy: .public)")
            }
            inputFormat = postStartFormat
        }
        if inputFormat.channelCount == 0 || inputFormat.sampleRate == 0 {
            var postAttempts = 0
            while (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) && postAttempts < 100 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                inputFormat = inputNode.auAudioUnit.outputBusses[0].format
                postAttempts += 1
            }
        }
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            audioEngineLog.error("AudioEngine.handleConfigurationChange: input format never bound after restart (channels=0 or sampleRate=0)")
            return
        }
        audioEngineLog.info("AudioEngine.handleConfigurationChange: new input bound — sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public). Reinstalling tap.")

        installTap(on: inputNode, inputFormat: inputFormat)
    }

    // MARK: - Engine recreate (private)

    /// Tear down and rebuild AVAudioEngine after a route change that the
    /// original instance can't recover from. Preserves `continuation`,
    /// `targetFormat`, `converterCache`, and `bufferCounter` so downstream
    /// AsyncStream consumers stay connected; only the AVAudioEngine and the
    /// notification observer are recreated. Returns true when the new engine
    /// is running and the tap is reinstalled on its inputNode.
    ///
    /// Why this exists: empirically, once `engine.start()` returns
    /// `-10868 kAudioUnitErr_FormatNotSupported` after a configuration
    /// change, the same engine instance will keep failing with the same
    /// error — the AUHAL caches the pre-swap format expectation and won't
    /// renegotiate. A fresh AVAudioEngine bootstraps on top of the current
    /// HAL state and binds cleanly.
    private func recreateEngineAfterRouteChange() async -> Bool {
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }
        engine?.stop()
        engine = nil

        let newEngine = AVAudioEngine()
        let newInputNode = newEngine.inputNode  // force AUHAL instantiation

        var inputFormat = newInputNode.auAudioUnit.outputBusses[0].format
        var attempts = 0
        while (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) && attempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            inputFormat = newInputNode.auAudioUnit.outputBusses[0].format
            attempts += 1
        }
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            audioEngineLog.error("AudioEngine.recreate: new AUHAL never bound a usable input format (channels=0 or sampleRate=0)")
            return false
        }

        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            audioEngineLog.error("AudioEngine.recreate: new engine.start failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
        self.engine = newEngine

        installTap(on: newInputNode, inputFormat: inputFormat)

        // Re-subscribe — the previous observer was bound (via `object:`) to
        // the dead engine and will never fire for the new instance.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleConfigurationChange()
            }
        }
        self.configChangeObserver = observer
        resetSupervisorBaseline()
        return true
    }

    // MARK: - Buffer-flow supervisor (private)

    /// Spin up the 1 s-cadence supervisor loop. Idempotent — cancels any
    /// existing task first. Called from `start()` after the first PCM buffer
    /// has been observed (so we don't fight the initial-startup ceiling).
    private func startSupervisor() {
        supervisorTask?.cancel()
        supervisorLastCount = bufferCounter?.snapshot.count ?? 0
        supervisorStalledTicks = 0
        supervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await self?.supervisorTick()
            }
        }
        audioEngineLog.info("AudioEngine.supervisor: started (1 s tick, \(self.supervisorStallThreshold, privacy: .public) s stall threshold)")
    }

    /// Cancel and drop the supervisor. Safe to call multiple times.
    private func stopSupervisor() {
        supervisorTask?.cancel()
        supervisorTask = nil
        supervisorLastCount = 0
        supervisorStalledTicks = 0
    }

    /// Re-baseline the supervisor whenever `bufferCounter` is replaced or
    /// reset (e.g. by `handleConfigurationChange`). Without this, the next
    /// tick reads `current < lastCount` and misinterprets the reset as a
    /// stall, doubling-up recovery attempts and churning the engine.
    private func resetSupervisorBaseline() {
        supervisorLastCount = bufferCounter?.snapshot.count ?? 0
        supervisorStalledTicks = 0
    }

    /// One supervisor tick. Reads the current buffer count, compares against
    /// the previous tick, and triggers `recreateEngineAfterRouteChange()` if
    /// the counter has been frozen for `supervisorStallThreshold` consecutive
    /// ticks. No-op when the engine is torn down, muted, or being recovered.
    private func supervisorTick() async {
        guard engine != nil, let counter = bufferCounter else {
            // Engine not running (between recordings, mid-teardown) — just
            // reset the stall counter so a future start() begins fresh.
            supervisorStalledTicks = 0
            return
        }
        if muteFlag.isMuted {
            // Live-mute still yields silence, but skip stall accounting because
            // user intent is "do not capture audible mic content".
            supervisorStalledTicks = 0
            supervisorLastCount = counter.snapshot.count
            return
        }
        let current = counter.snapshot.count
        if current != supervisorLastCount {
            supervisorLastCount = current
            supervisorStalledTicks = 0
            return
        }
        supervisorStalledTicks += 1
        if supervisorStalledTicks < supervisorStallThreshold {
            return
        }
        audioEngineLog.error("AudioEngine.supervisor: no new buffers for ~\(self.supervisorStalledTicks, privacy: .public) s while engine is supposedly live — rebuilding from scratch to recover from silent HAL stall (route change, SCStream startup, BT SCO drop, etc.)")
        supervisorStalledTicks = 0
        let recreated = await recreateEngineAfterRouteChange()
        if recreated {
            audioEngineLog.info("AudioEngine.supervisor: recreate succeeded — mic should resume")
        } else {
            audioEngineLog.error("AudioEngine.supervisor: recreate failed — will retry on next stall window")
        }
        // After recreate, bufferCounter is preserved (recreate doesn't reset
        // it). Re-baseline so the next tick measures from the post-recreate
        // count, not the stale pre-recreate count.
        if let c = bufferCounter {
            supervisorLastCount = c.snapshot.count
        }
    }
}

// MARK: - Errors

public enum AudioEngineError: Error, Sendable, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case engineStartFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Could not create the target audio format. This is unexpected — please report it."
        case .converterCreationFailed:
            return "Could not create the audio sample-rate converter."
        case .engineStartFailed(let underlying):
            // Surface the underlying NSError's localized description directly
            // so users see "Microphone tap installed but no audio arrived..."
            // instead of "AudioEngineError error 0".
            return underlying.localizedDescription
        }
    }
}

// MARK: - ConverterCache

/// Small reference holder for an AVAudioConverter that gets built on demand
/// when the first PCM buffer arrives. Used by AudioEngine's tap callback,
/// which runs on a real-time audio thread — building once and reusing.
private final class ConverterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func converter(from source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        // Locking even though the tap callback is the dominant caller —
        // future audio-format changes (sample-rate switch on a connected
        // device) trigger writes from a different thread, and the
        // unsynchronized read+write was a Swift 6 strict-concurrency data
        // race. NSLock here is sub-microsecond; tap fires at ~10 Hz; lock
        // contention is non-existent.
        lock.lock(); defer { lock.unlock() }
        if let existing = converter,
           let cachedSource = sourceFormat,
           cachedSource.sampleRate == source.sampleRate,
           cachedSource.channelCount == source.channelCount,
           cachedSource.commonFormat == source.commonFormat {
            return existing
        }
        let new = AVAudioConverter(from: source, to: target)
        converter = new
        sourceFormat = source
        return new
    }
}
