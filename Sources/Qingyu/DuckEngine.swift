// DuckEngine.swift — vendored from the speak-duck project (rhklite/speak-duck),
// which 轻语 now includes as an optional "quiet other audio while I dictate" feature.
//
// Two deliberate changes from the original:
//   1. Everything is gated @available(macOS 14.4, *). The Core Audio process-tap API
//      (AudioHardwareCreateProcessTap / CATapDescription) landed in 14.4, while 轻语
//      itself targets macOS 13 so it still runs on older Intel Macs. The feature is
//      simply unavailable below 14.4 rather than dragging the whole app forward.
//   2. `manualDictating`: speak-duck sniffs the process list for a dictation app
//      holding the mic. 轻语 *is* the dictation app and knows exactly when it is
//      recording, so it drives the trigger directly — no bundle-ID guessing, no
//      polling latency.
//
// Original header follows.
// Engine.swift — universal system-wide ducker (on-demand volume lowering).
//
// While Spoken Content (Speak Selection / hover-speak) talks, a global Core Audio
// process tap captures ALL other audio (voice process excluded so it stays clear)
// and mutes it from the normal output path. A separate IOProc on the real output
// device then REPLAYS the captured audio at `duckLevel` gain — so background media
// is *lowered*, not silenced. Our own process is excluded from the tap so the
// replay isn't re-captured (feedback). Writing into the aggregate's own output
// buffers does NOT reach the speakers (verified) — hence the replay device.
// duckLevel 0 == full mute (no replay, old behavior), 1 == untouched. The tap
// exists ONLY during speech — at idle there is no tap, so audio is never touched.
//
// No special permission needed for the tap on this macOS. SPEAKDUCK_DEBUG=1 logs.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Core Audio helpers

@available(macOS 14.4, *)
func processList() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

@available(macOS 14.4, *)
func uint32Prop(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
    return value
}

@available(macOS 14.4, *)
func pidProp(_ obj: AudioObjectID) -> pid_t {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
    return value
}

@available(macOS 14.4, *)
func bundleID(_ obj: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(obj, &addr) else { return nil }
    var size = UInt32(MemoryLayout<CFString?>.size)
    var result: Unmanaged<CFString>? = nil
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &result) == noErr,
          let r = result else { return nil }
    let s = r.takeRetainedValue() as String
    return s.isEmpty ? nil : s
}

@available(macOS 14.4, *)
func defaultOutputDevice() -> AudioObjectID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
    return dev
}

@available(macOS 14.4, *)
func deviceUID(_ dev: AudioObjectID) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
    return cf.takeRetainedValue() as String
}

// Audio object for OUR pid (exists only while we do audio IO somewhere).
@available(macOS 14.4, *)
func selfProcessObject() -> AudioObjectID? {
    var pid: pid_t = getpid()
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr,
        UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
}

// Single-producer single-consumer Float ring buffer shared between the capture
// IOProc (writer) and the replay IOProc (reader). Monotonic 64-bit indices;
// aligned 64-bit loads/stores are atomic on arm64/x86_64, adequate for SPSC here.
@available(macOS 14.4, *)
final class FloatRing {
    let capacity: Int   // power of two, in samples
    private let mask: UInt64
    private let data: UnsafeMutablePointer<Float>
    private let widx: UnsafeMutablePointer<UInt64>
    private let ridx: UnsafeMutablePointer<UInt64>

    init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0)
        self.capacity = capacity
        self.mask = UInt64(capacity - 1)
        data = .allocate(capacity: capacity); data.initialize(repeating: 0, count: capacity)
        widx = .allocate(capacity: 1); widx.initialize(to: 0)
        ridx = .allocate(capacity: 1); ridx.initialize(to: 0)
    }
    deinit { data.deallocate(); widx.deallocate(); ridx.deallocate() }

    func reset() { ridx.pointee = widx.pointee }

    func write(_ src: UnsafePointer<Float>, _ n: Int) {
        let w = widx.pointee
        for i in 0..<n { data[Int((w &+ UInt64(i)) & mask)] = src[i] }
        widx.pointee = w &+ UInt64(n)
    }

    // Read up to n samples scaled by gain; zero-fill any shortfall. If the reader
    // has fallen more than a full buffer behind, jump forward to bound latency.
    func read(into dst: UnsafeMutablePointer<Float>, _ n: Int, gain: Float) {
        var r = ridx.pointee
        let w = widx.pointee
        if w &- r > UInt64(capacity) { r = w &- UInt64(capacity) }
        let take = min(n, Int(w &- r))
        for i in 0..<take { dst[i] = data[Int((r &+ UInt64(i)) & mask)] * gain }
        if take < n { for i in take..<n { dst[i] = 0 } }
        ridx.pointee = r &+ UInt64(take)
    }
}

@available(macOS 14.4, *)
let stamp: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()
@available(macOS 14.4, *)
func log(_ msg: String) { print("\(stamp.string(from: Date()))  \(msg)") }

@available(macOS 14.4, *)
let DEBUG = ProcessInfo.processInfo.environment["SPEAKDUCK_DEBUG"] != nil
@available(macOS 14.4, *)
func dlog(_ msg: String) { if DEBUG { log("· \(msg)") } }

// MARK: - Action modes

/// What the engine does while Spoken Content is talking.
/// - off:   nothing (armed but idle).
/// - duck:  lower/mute all background audio via the process tap (original behavior).
/// - pause: pause the macOS "Now Playing" source via MediaRemote, then resume it
///          when speech ends. Reaches any Now-Playing-aware source (Music, Spotify,
///          Safari, modern Chrome, and iPhone→Mac AirPlay).
@available(macOS 14.4, *)
enum DuckMode: Int { case off = 0, duck = 1, pause = 2 }

// MARK: - Universal duck engine (on-demand duck / pause)

@available(macOS 14.4, *)
final class DuckEngine {
    private let voiceBundle: String
    private let resumeDelay: TimeInterval

    // Gain applied to background audio while speaking, read live from the real-time
    // audio IO thread. Heap-allocated so the IOProc block touches only a raw pointer
    // (no Swift runtime / locks on the audio thread). 0 == mute, 1 == untouched.
    private let gainPtr: UnsafeMutablePointer<Float>

    /// Fraction (0...1) to lower background audio to while speaking. 0 mutes.
    var duckLevel: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(0, min(1, newValue)) }
    }

    /// Called on the main queue when an action becomes active (true) or clears
    /// (false) — used by the menu-bar UI to update its icon and status line.
    var onMute: ((Bool) -> Void)?

    /// Injected by the AppKit layer: deterministic MediaRemote pause/play of the Now
    /// Playing session. Used by pause actions (Core Audio can't pause a source, only
    /// intercept its output).
    var sendPause: (() -> Void)?
    var sendPlay: (() -> Void)?

    /// When true, also pause media while a dictation app (Wispr Flow) holds the mic,
    /// independent of `mode` — dictation always pauses (never ducks), so the mic is
    /// not left capturing the media it's supposed to be transcribing over.
    var pauseWhileDictating = false

    /// Set by 轻语 around its own recording. Unlike the process-list sniffing below
    /// this is exact: no bundle-ID list to maintain and no 50 ms poll to wait for.
    var manualDictating = false
    private let dictationPrefix = "com.electron.wispr-flow"

    // Non-pausable system audio sources whose output must NOT be read as "media
    // playing": MediaRemote play/pause has no effect on them, so counting them as
    // media makes us arm a resume and then fire a global PLAY that inadvertently
    // unpauses the user's real (already-paused) media. Real MediaRemote-controllable
    // media always comes from an actual app (Chrome/Music/Spotify/Safari…), never
    // these daemons, so excluding them is safe. avconferenced carries FaceTime /
    // AirPlay / call audio; systemsoundserverd renders alert / UI / notification
    // sounds. Matched by bundle-ID prefix; extend as other daemons surface.
    private let nonMediaPrefixes = [
        "com.apple.avconferenced",
        "systemsoundserverd",
        "com.apple.systemsoundserverd",
    ]

    /// Active action mode. Changing it live tears down whatever the old mode was
    /// doing (restores volume / resumes media) so we never leave media stuck.
    var mode: DuckMode = .duck {
        didSet {
            guard mode != oldValue else { return }
            queue.async { [self] in pendingEnd?.cancel(); pendingEnd = nil; end() }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var playDev = AudioObjectID(kAudioObjectUnknown)
    private var playProc: AudioDeviceIOProcID?
    private let ring = FloatRing(capacity: 1 << 17)   // ~1.3 s stereo @ 48 kHz
    private var muting = false          // duck action active (tap up)
    private var paused = false          // pause action active (media paused by us)
    private var active: Bool { muting || paused }
    private var pendingEnd: DispatchWorkItem?
    private let queue = DispatchQueue(label: "speak-duck.engine")
    private var pollTimer: DispatchSourceTimer?

    init(voiceBundle: String, resumeDelay: TimeInterval, duckLevel: Float = 0) {
        self.voiceBundle = voiceBundle
        self.resumeDelay = resumeDelay
        self.gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        self.gainPtr.initialize(to: max(0, min(1, duckLevel)))
    }

    deinit { gainPtr.deallocate() }

    private func voiceObjects() -> [AudioObjectID] { processList().filter { bundleID($0) == voiceBundle } }

    @discardableResult
    func start() -> Bool {
        let p = DispatchSource.makeTimerSource(queue: queue)
        p.schedule(deadline: .now() + 0.05, repeating: 0.05)
        p.setEventHandler { [weak self] in self?.poll() }
        p.resume(); pollTimer = p
        dlog("engine started for \(voiceBundle)")
        // Debug self-test: SPEAKDUCK_PROBE_TEST=1 measures the audibility probe once
        // at launch (with and without exclusions) and logs the peaks.
        if ProcessInfo.processInfo.environment["SPEAKDUCK_PROBE_TEST"] != nil {
            queue.asyncAfter(deadline: .now() + 1.0) { [self] in
                let peak = audibleMediaPeak(excluding: voiceObjects(), window: probeWindow)
                log("PROBE TEST peak=\(peak)")
            }
        }
        return true
    }

    func stop() {
        pollTimer?.cancel(); pollTimer = nil
        queue.sync { pendingEnd?.cancel(); pendingEnd = nil; end() }   // resume media if paused
    }

    private func poll() {
        let objs = voiceObjects()
        let speaking = mode != .off && objs.contains { uint32Prop($0, kAudioProcessPropertyIsRunningOutput) != 0 }
        let dictating = pauseWhileDictating && (manualDictating || dictationActive())
        if speaking || dictating {
            pendingEnd?.cancel(); pendingEnd = nil
            // Spoken Content uses the selected mode (duck or pause); a dictation-only
            // trigger always pauses. Either trigger keeps media suppressed until both clear.
            if !active { begin(excluding: objs) }
        } else if active, pendingEnd == nil {
            let w = DispatchWorkItem { [weak self] in self?.end(); self?.pendingEnd = nil }
            pendingEnd = w
            queue.asyncAfter(deadline: .now() + resumeDelay, execute: w)
        }
    }

    /// True while a dictation app (e.g. Wispr Flow) is capturing the mic — the input
    /// mirror of the Spoken-Content output check. Its helper process flips
    /// kAudioProcessPropertyIsRunningInput only while actively dictating.
    private func dictationActive() -> Bool {
        for obj in processList() where uint32Prop(obj, kAudioProcessPropertyIsRunningInput) != 0 {
            if let b = bundleID(obj), b.hasPrefix(dictationPrefix) { return true }
        }
        return false
    }

    // Dispatch the current mode's start/stop action. `end()` keys off the active
    // flags (not `mode`) so a mid-action mode switch still unwinds correctly.
    private func begin(excluding objs: [AudioObjectID]) {
        switch mode {
        case .off:   break
        case .duck:  beginMute(excluding: objs)
        case .pause: beginPause(voice: objs)
        }
    }

    private func end() {
        if muting { endMute() }
        if paused { endPause() }
    }

    // MARK: Pause action (MediaRemote)

    // True if any process other than the voice, ourselves, and the dictation app is
    // currently producing output. Guards the resume: we only send play afterwards if
    // media was actually playing when the trigger began — else a stray "play" on
    // release would START playback the user never had. The dictation app is excluded
    // because its helper keeps an output stream running even when idle.
    private func mediaIsPlaying(excluding voice: [AudioObjectID]) -> Bool {
        let voiceSet = Set(voice)
        let me = getpid()
        for obj in processList() {
            if voiceSet.contains(obj) || pidProp(obj) == me { continue }
            if let b = bundleID(obj), b.hasPrefix(dictationPrefix) || nonMediaPrefixes.contains(where: b.hasPrefix) { continue }
            if uint32Prop(obj, kAudioProcessPropertyIsRunningOutput) != 0 { return true }
        }
        return false
    }

    // The output FLAG alone is not proof of playing media: players (Chrome notably)
    // keep their output unit open for a while after the user pauses, and resuming
    // then would START media the user had deliberately stopped. So when flags say
    // "playing", verify there is actually AUDIBLE audio by sampling the real mix for
    // a moment with a capture-only (unmuted) tap before arming the resume.
    private let probeWindow: TimeInterval = 0.6        // must exceed ~175 ms tap warm-up
    private let probeThreshold: Float = 0.001          // ~-60 dBFS peak
    private var lastSilentProbe: Date?                 // throttles re-probing while silent

    private func beginPause(voice: [AudioObjectID]) {
        // No mode guard: callers gate this (begin() only for .pause; poll() for dictation).
        guard mediaIsPlaying(excluding: voice) else { dlog("pause: nothing playing → skip"); return }
        if let t = lastSilentProbe, Date().timeIntervalSince(t) < 1.0 { return }
        let peak = audibleMediaPeak(excluding: voice, window: probeWindow)
        guard peak > probeThreshold else {
            lastSilentProbe = Date()
            dlog("pause: output open but silent (peak \(peak)) → skip")
            return
        }
        lastSilentProbe = nil
        sendPause?()
        paused = true
        log("speaking → media paused")
        DispatchQueue.main.async { self.onMute?(true) }
    }

    /// Peak absolute sample of all non-voice/self/dictation output, measured via a
    /// capture-only tap (muteBehavior .unmuted — audio is unaffected). The tap takes
    /// ~175 ms to warm up before real audio flows (measured), so the probe samples
    /// with early exit: it returns as soon as anything audible is seen and only
    /// declares silence after `window` (which must comfortably exceed warm-up).
    /// Returns 0 (silent) if the probe can't be built, so callers FAIL CLOSED —
    /// skip the pause rather than arm a resume that could later fire a global PLAY
    /// and unpause the user's real media. A missed pause is the cheaper failure.
    private func audibleMediaPeak(excluding voice: [AudioObjectID], window: TimeInterval) -> Float {
        var excluded = voice
        if let me = selfProcessObject() { excluded.append(me) }
        for obj in processList() {
            if let b = bundleID(obj), b.hasPrefix(dictationPrefix) || nonMediaPrefixes.contains(where: b.hasPrefix) {
                excluded.append(obj)   // keep FaceTime/AirPlay, notification/UI sounds & dictation out of the peak
            }
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "speak-duck-probe"; desc.isPrivate = true; desc.muteBehavior = .unmuted
        var probeTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &probeTap) == noErr else { dlog("probe: tap create failed → fail-closed"); return 0 }
        defer { AudioHardwareDestroyProcessTap(probeTap) }
        guard let outUID = deviceUID(defaultOutputDevice()) else { dlog("probe: output UID nil → fail-closed"); return 0 }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "speak-duck-probe-agg",
            kAudioAggregateDeviceUIDKey: "speak-duck-probe-agg-\(getpid())",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var probeAgg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &probeAgg) == noErr else { dlog("probe: aggregate create failed → fail-closed"); return 0 }
        defer { AudioHardwareDestroyAggregateDevice(probeAgg) }
        let peakPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        peakPtr.initialize(to: 0)
        defer { peakPtr.deallocate() }
        var proc: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { _, inData, _, out, _ in
            let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            if inBL.count > 0, let src = inBL[0].mData {
                let p = src.assumingMemoryBound(to: Float.self)
                let n = Int(inBL[0].mDataByteSize) / MemoryLayout<Float>.size
                var m = peakPtr.pointee
                for i in 0..<n { let a = abs(p[i]); if a > m { m = a } }
                peakPtr.pointee = m
            }
            for b in UnsafeMutableAudioBufferListPointer(out) {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, probeAgg, nil, block) == noErr, let p = proc else { dlog("probe: ioproc create failed → fail-closed"); return 0 }
        AudioDeviceStart(probeAgg, p)
        let steps = max(1, Int(window / 0.025))
        for _ in 0..<steps {
            usleep(25_000)
            if peakPtr.pointee > probeThreshold { break }   // audible → done early
        }
        AudioDeviceStop(probeAgg, p)
        AudioDeviceDestroyIOProcID(probeAgg, p)
        return peakPtr.pointee
    }

    private func endPause() {
        guard paused else { return }
        paused = false
        sendPlay?()
        log("speech ended → media resumed")
        DispatchQueue.main.async { self.onMute?(false) }
    }

    // Start the replay IOProc on the real output device: pulls captured background
    // audio from the ring at the current gain. Doing IO here also registers OUR
    // process with coreaudiod so the tap can exclude us (no feedback loop).
    private func startReplay() -> Bool {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return false }
        ring.reset()
        let ring = self.ring, gainPtr = self.gainPtr
        let block: AudioDeviceIOBlock = { _, _, _, out, _ in
            var first = true
            for b in UnsafeMutableAudioBufferListPointer(out) {
                guard let d = b.mData else { continue }
                if first {
                    ring.read(into: d.assumingMemoryBound(to: Float.self),
                              Int(b.mDataByteSize) / MemoryLayout<Float>.size,
                              gain: gainPtr.pointee)
                    first = false
                } else { memset(d, 0, Int(b.mDataByteSize)) }
            }
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&playProc, dev, nil, block) == noErr,
              let p = playProc, AudioDeviceStart(dev, p) == noErr else {
            stopReplay(); dlog("replay ioproc failed"); return false
        }
        playDev = dev
        return true
    }

    private func stopReplay() {
        if let p = playProc {
            if playDev != kAudioObjectUnknown { AudioDeviceStop(playDev, p); AudioDeviceDestroyIOProcID(playDev, p) }
            playProc = nil
        }
        playDev = AudioObjectID(kAudioObjectUnknown)
    }

    private func beginMute(excluding objs: [AudioObjectID]) {
        guard mode == .duck else { return }

        // Partial duck: start replay first, then exclude ourselves from the tap.
        var excluded = objs
        var replaying = false
        if gainPtr.pointee > 0, startReplay() {
            var me = selfProcessObject()
            for _ in 0..<4 where me == nil { usleep(50_000); me = selfProcessObject() }
            if let me {
                excluded.append(me); replaying = true
            } else {
                dlog("self process object not found → falling back to full mute")
                stopReplay()
            }
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "speak-duck-tap"; desc.isPrivate = true; desc.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { dlog("tap failed"); stopReplay(); return }
        guard let outUID = deviceUID(defaultOutputDevice()) else { teardown(); return }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "speak-duck-agg",
            kAudioAggregateDeviceUIDKey: "speak-duck-agg-\(getpid())",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID) == noErr else { dlog("agg failed"); teardown(); return }
        // Capture the tapped (muted) background audio into the ring for the replay
        // IOProc. Writing to the aggregate's own output buffers never reaches the
        // speakers, so output is just zeroed. Tap format is Float32 PCM.
        let ring = self.ring
        let block: AudioDeviceIOBlock = { _, inData, _, out, _ in
            if replaying {
                let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                if inBL.count > 0, let src = inBL[0].mData {
                    ring.write(src.assumingMemoryBound(to: Float.self),
                               Int(inBL[0].mDataByteSize) / MemoryLayout<Float>.size)
                }
            }
            for b in UnsafeMutableAudioBufferListPointer(out) {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil, block) == noErr, ioProc != nil else { dlog("ioproc failed"); teardown(); return }
        AudioDeviceStart(aggID, ioProc)
        muting = true
        let pct = Int((gainPtr.pointee * 100).rounded())
        log("speaking → media \(replaying ? "lowered to \(pct)%" : "muted") (voice excluded: \(objs.count))")
        DispatchQueue.main.async { self.onMute?(true) }
    }

    private func endMute() {
        let was = muting
        teardown()
        muting = false
        if was {
            log("speech ended → media restored")
            DispatchQueue.main.async { self.onMute?(false) }
        }
    }

    private func teardown() {
        if let p = ioProc { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); ioProc = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        stopReplay()
    }
}
