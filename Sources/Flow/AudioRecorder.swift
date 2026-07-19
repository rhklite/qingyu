import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures microphone audio and resamples it to the 16 kHz mono float format
/// whisper.cpp expects. The tap runs on a real-time audio thread, so the sample
/// buffer is guarded by a lock.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Hard cap so a forgotten hotkey can't grow the buffer without bound (~5 min).
    private let maxSamples = 16_000 * 300

    /// Pinned input-device UID (from Config). nil / empty = follow the system default.
    var preferredDeviceUID: String?

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        applyPreferredDevice(to: input)
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the collected 16 kHz mono samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        return out
    }

    /// Pin capture to the user-selected input device (by CoreAudio UID). Falls back
    /// to the system default when nothing is pinned or the device is disconnected.
    private func applyPreferredDevice(to input: AVAudioInputNode) {
        guard let uid = preferredDeviceUID, !uid.isEmpty,
              let devID = AudioDevices.deviceID(forUID: uid),
              let au = input.audioUnit else { return }
        var dev = devID
        _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
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
    }
}
