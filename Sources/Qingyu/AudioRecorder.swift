import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures microphone audio and resamples it to the 16 kHz mono float format
/// whisper.cpp expects. The tap runs on a real-time audio thread, so the sample
/// buffer is guarded by a lock.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Hard cap so a forgotten hotkey can't grow the buffer without bound (~5 min).
    private let maxSamples = 16_000 * 300

    /// Pinned input-device UID (from Config). nil / empty = follow the system default.
    var preferredDeviceUID: String?

    /// Live input level (0…1), emitted per buffer on the audio thread for UI meters.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue if capture can't start (surfaces the error to the UI).
    var onError: ((Error) -> Void)?

    private let audioQueue = DispatchQueue(label: "com.local.flow.audio")
    private var built = false
    private var builtForUID: String?
    private var wantRecording = false          // desired state; guarded by `lock`

    /// Begin capturing. Non-blocking: the mic/HAL spins up on a background queue so the
    /// UI (bar + chime) responds instantly. The audio graph is reused across recordings;
    /// only the first use or a device change pays the rebuild cost.
    func start() {
        lock.lock(); samples.removeAll(keepingCapacity: true); wantRecording = true; lock.unlock()
        let target = (preferredDeviceUID?.isEmpty == false) ? preferredDeviceUID : nil
        audioQueue.async { [weak self] in
            guard let self, self.isWanted() else { return }   // already released → don't open the mic
            do {
                try self.ensureRunning(deviceUID: target)
            } catch {
                guard target != nil else { self.report(error); return }
                NSLog("Qingyu: pinned mic failed (%@); using system default", error.localizedDescription as NSString)
                do { try self.ensureRunning(deviceUID: nil, forceRebuild: true) }
                catch { self.report(error); return }
            }
            if !self.isWanted() { self.engine.stop() }        // released during spin-up → close now
        }
    }

    /// Stop capturing and return the collected samples. Releases the mic immediately —
    /// no warm-up lingering — so its indicator turns off the moment you finish speaking.
    func stop() -> [Float] {
        lock.lock(); wantRecording = false; let out = samples; samples.removeAll(); lock.unlock()
        audioQueue.async { [weak self] in self?.engine.stop() }
        return out
    }

    /// Boost a quiet / far-from-mic utterance to a consistent loudness for whisper
    /// (RMS gain with a peak limiter so it never clips). Only amplifies — never reduces —
    /// so already-loud speech is left alone and background noise isn't over-amplified.
    static func normalizedForRecognition(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var sumSq: Float = 0, peak: Float = 0
        for s in samples { sumSq += s * s; peak = Swift.max(peak, abs(s)) }
        let rms = (sumSq / Float(samples.count)).squareRoot()
        guard rms > 1e-5, peak > 0 else { return samples }   // silence → leave untouched

        let targetRMS: Float = 0.12
        var gain = targetRMS / rms
        gain = Swift.min(gain, 0.97 / peak)   // peak limiter — never clip
        gain = Swift.min(gain, 8.0)           // cap at ~+18 dB so faint noise isn't blown up
        gain = Swift.max(gain, 1.0)           // boost-only
        guard gain > 1.02 else { return samples }
        return samples.map { $0 * gain }
    }

    private func isWanted() -> Bool { lock.lock(); defer { lock.unlock() }; return wantRecording }
    private func report(_ error: Error) { if let onError { DispatchQueue.main.async { onError(error) } } }

    /// Reuse the audio graph across recordings: the expensive rebuild (new engine +
    /// device selection + tap install) runs only on first use or when the pinned device
    /// changes. A warm start is just a flag flip; a cold start only restarts the HAL.
    /// Building a fresh engine on every press was the startup-latency cause.
    private func ensureRunning(deviceUID: String?, forceRebuild: Bool = false) throws {
        if forceRebuild || !built || builtForUID != deviceUID {
            try build(deviceUID: deviceUID)
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func build(deviceUID: String?) throws {
        if built {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, !uid.isEmpty,
           let devID = AudioDevices.deviceID(forUID: uid),
           let au = input.audioUnit {
            var dev = devID
            let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                throw NSError(domain: "Qingyu.Audio", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "could not select the pinned input device"])
            }
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else {
            throw NSError(domain: "Qingyu.Audio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "input device has no usable audio format"])
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        // Only accumulate while a recording is actually wanted (the tap may still be
        // installed for a moment as the engine tears down).
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, self.isWanted() else { return }
            self.append(buffer)
        }
        engine.prepare()
        built = true
        builtForUID = deviceUID
    }

    private func append(_ inBuffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if supplied { inStatus.pointee = .noDataNow; return nil }
            supplied = true
            inStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, let ch = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        lock.lock()
        if samples.count < maxSamples {
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        }
        lock.unlock()

        // RMS → normalized level for the floating meter. Gain maps typical speech
        // energy into a lively 0…1 range; silence stays near zero.
        if let onLevel, n > 0 {
            let p = ch[0]
            var sum: Float = 0
            for i in 0..<n { let s = p[i]; sum += s * s }
            let rms = (sum / Float(n)).squareRoot()
            onLevel(min(1, rms * 8))
        }
    }
}
