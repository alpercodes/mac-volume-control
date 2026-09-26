import CoreAudio
import Foundation
import Synchronization

/// Captures the audio of a set of processes with a Core Audio process tap (which mutes their normal output while
/// it is being read) and plays it back on the output device at an adjustable gain.
final class VolumeTap {
    private(set) var processObjectIDs: Set<AudioObjectID>
    let outputDevice: AudioDeviceID
    /// The output device's format when the tap was built (see `formatSignature`); a tap doesn't survive a change.
    let deviceSignature: String

    private let description: CATapDescription
    private var renderer: GainRenderer?
    private var initialGain: Float
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: Set<AudioObjectID>, outputDevice: AudioDeviceID, deviceSignature: String, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDevice = outputDevice
        self.deviceSignature = deviceSignature
        self.initialGain = gain
        self.description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs.sorted())

        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    var gain: Float {
        get { renderer?.targetGain ?? initialGain }
        set {
            initialGain = newValue
            renderer?.targetGain = newValue
        }
    }

    /// Peak level of the captured audio in the most recent IO cycle (before gain).
    var inputPeak: Float { renderer?.inputPeak ?? 0 }

    /// Number of IO cycles that played the tapped audio, to tell a working tap from a stalled one. Cycles that
    /// couldn't (say, the device's layout changed under us) don't count: the app is muted all the same.
    var ioCycles: UInt64 { renderer?.renderedCycles ?? 0 }

    /// The last IO cycle that captured anything but digital silence (0 if none has yet).
    var lastAudibleCycle: UInt64 { renderer?.lastAudibleCycle ?? 0 }

    /// Changes which processes are tapped without rebuilding, so the audio doesn't drop out or jump in volume.
    func updateProcesses(_ processObjectIDs: Set<AudioObjectID>) throws {
        description.processes = processObjectIDs.sorted()
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var value: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        try check(status, "Updating tapped processes")
        self.processObjectIDs = processObjectIDs
    }

    private func start() throws {
        description.uuid = UUID()
        description.name = "Volume Control"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")

        let format: AudioStreamBasicDescription = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0 else {
            throw CoreAudioError(operation: "Unsupported tap format", status: kAudioHardwareUnsupportedOperationError)
        }

        let outputUID = try outputDevice.deviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Control",
            kAudioAggregateDeviceUIDKey: "dev.alper.VolumeControl.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating aggregate device")

        // The aggregate's input streams are the output device's own inputs (e.g. a headset mic) followed by the tap.
        // Check that, and that there's somewhere to play to, before muting the app: otherwise it would go silent.
        let deviceInputStreams = outputDevice.streamCount(scope: kAudioObjectPropertyScopeInput)
        let inputChannels = aggregateID.bufferChannelCounts(scope: kAudioObjectPropertyScopeInput)
        let outputChannels = aggregateID.bufferChannelCounts(scope: kAudioObjectPropertyScopeOutput)
        let transport: UInt32 = (try? outputDevice.read(kAudioDevicePropertyTransportType, default: 0)) ?? 0
        let unsupported = transport == kAudioDeviceTransportTypeAggregate
            ? "Multi-Output and aggregate devices aren't supported. Choose a regular output device in Sound settings."
            : nil
        guard aggregateID.streamCount(scope: kAudioObjectPropertyScopeInput) == deviceInputStreams + 1,
              inputChannels.last == Int(format.mChannelsPerFrame) else {
            throw TapError(description: unsupported ?? "This output device isn't supported (inputs \(inputChannels)).")
        }
        let stereo = outputDevice.preferredStereoChannels()
        guard let left = OutputChannel(stereo.left, in: outputChannels) ?? OutputChannel(0, in: outputChannels) else {
            throw TapError(description: unsupported ?? "This output device has no output channels.")
        }
        let right = OutputChannel(stereo.right, in: outputChannels).flatMap { $0 == left ? nil : $0 }

        let deviceRate: Float64 = (try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: 0)) ?? 0
        if deviceRate != format.mSampleRate {
            log.warning("Tap runs at \(format.mSampleRate) Hz but the output device at \(deviceRate) Hz")
        }

        let renderer = GainRenderer(gain: initialGain, tapChannels: Int(format.mChannelsPerFrame), left: left, right: right)
        self.renderer = renderer
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }, "Creating IO proc")
        if deviceInputStreams > 0, let ioProcID {
            // Only read the tap, never the device's microphone: opening it would switch AirPods to low-quality
            // call mode and need microphone permission.
            try enableInputStreams(from: deviceInputStreams, of: aggregateID, for: ioProcID)
        }
        if !outputDevice.setDuckingOptOut(true) {
            log.warning("Couldn't opt out of ducking; audio may be too quiet during calls")
        }
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting aggregate device")

        // coreaudiod only applies the exemption to streams that are already running (otherwise it kicks in at the
        // next system volume change), so repeat it once ours is.
        let device = outputDevice
        for delay in [0.1, 0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.tapID.isValid else { return }
                _ = device.setDuckingOptOut(true)
            }
        }
    }

    /// Forgets the Core Audio objects without destroying them, for when coreaudiod restarted and their IDs are dead.
    func abandon() {
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    func invalidate() {
        if aggregateID.isValid {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }
}

struct TapError: Error, CustomStringConvertible {
    let description: String
}

/// Turns off the input streams before `firstEnabled` for the given IO proc.
func enableInputStreams(from firstEnabled: Int, of device: AudioDeviceID, for ioProcID: AudioDeviceIOProcID) throws {
    let streamCount = device.streamCount(scope: kAudioObjectPropertyScopeInput)
    let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!
    let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    let size = max(flagsOffset + streamCount * MemoryLayout<UInt32>.stride, MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
    let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
    defer { usage.deallocate() }
    usage.initializeMemory(as: UInt8.self, repeating: 0, count: size)

    usage.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
    usage.storeBytes(of: UInt32(streamCount), toByteOffset: countOffset, as: UInt32.self)
    for index in 0..<streamCount {
        usage.storeBytes(of: index >= firstEnabled ? 1 : 0, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
    }
    var address = AudioObjectPropertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
    try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage), "Disabling device input streams")
}

/// Where one output channel lives in the IO proc's output buffer list.
struct OutputChannel: Equatable {
    let buffer: Int
    let offset: Int
    let stride: Int

    /// `channel` is zero-based across all buffers; `bufferChannels` is the channel count of each buffer.
    init?(_ channel: Int, in bufferChannels: [Int]) {
        var first = 0
        for (buffer, count) in bufferChannels.enumerated() {
            if channel >= first && channel < first + count {
                self.buffer = buffer
                self.offset = channel - first
                self.stride = count
                return
            }
            first += count
        }
        return nil
    }
}

/// Real-time part of the tap. `render` runs on the audio IO thread, so it only uses precomputed, immutable layout
/// and raw pointers: no allocation, locks or generic runtime calls.
private final class GainRenderer: @unchecked Sendable {
    private let targetGainBits: Atomic<UInt32>
    private let inputPeakBits = Atomic<UInt32>(0)
    private let cycleCount = Atomic<UInt64>(0)
    private let renderedCycleCount = Atomic<UInt64>(0)
    private let lastAudibleCycleCount = Atomic<UInt64>(0)
    private var currentGain: Float  // IO thread only

    private let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    private let tapChannels: Int
    private let left: OutputChannel
    private let right: OutputChannel?

    init(gain: Float, tapChannels: Int, left: OutputChannel, right: OutputChannel?) {
        targetGainBits = Atomic(gain.bitPattern)
        currentGain = gain
        self.tapChannels = tapChannels
        self.left = left
        self.right = right
    }

    var targetGain: Float {
        get { Float(bitPattern: targetGainBits.load(ordering: .relaxed)) }
        set { targetGainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var inputPeak: Float { Float(bitPattern: inputPeakBits.load(ordering: .relaxed)) }
    var renderedCycles: UInt64 { renderedCycleCount.load(ordering: .relaxed) }
    var lastAudibleCycle: UInt64 { lastAudibleCycleCount.load(ordering: .relaxed) }

    /// Hard clip at unity gain or below; above it, round off peaks so boosted audio doesn't crackle.
    @inline(__always)
    private func limit(_ sample: Float, soft: Bool) -> Float {
        guard soft else { return min(max(sample, -1), 1) }
        let knee: Float = 0.8
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let limited = knee + (1 - knee) * tanhf((magnitude - knee) / (1 - knee))
        return sample < 0 ? -limited : limited
    }

    @inline(__always)
    private func buffers(_ list: UnsafePointer<AudioBufferList>) -> (UnsafePointer<AudioBuffer>, Int) {
        let buffers = UnsafeRawPointer(list).advanced(by: buffersOffset).assumingMemoryBound(to: AudioBuffer.self)
        return (buffers, Int(list.pointee.mNumberBuffers))
    }

    /// The samples of `channel` (already offset to its first sample) and how many frames its buffer holds.
    @inline(__always)
    private func samples(for channel: OutputChannel, in buffers: UnsafePointer<AudioBuffer>, count: Int)
        -> (UnsafeMutablePointer<Float>, Int)? {
        guard channel.buffer < count else { return nil }
        let buffer = buffers[channel.buffer]
        guard Int(buffer.mNumberChannels) == channel.stride, let data = buffer.mData else { return nil }
        let frames = Int(buffer.mDataByteSize) / (channel.stride * MemoryLayout<Float>.size)
        return (data.assumingMemoryBound(to: Float.self) + channel.offset, frames)
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let cycle = cycleCount.add(1, ordering: .relaxed).newValue

        let (outBuffers, outCount) = buffers(UnsafePointer(output))
        for index in 0..<outCount {
            let buffer = outBuffers[index]
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let (inBuffers, inCount) = buffers(input)
        // The tap is the aggregate's last input, after any of the device's own (which can appear, e.g. a headset's
        // microphone once it switches to call mode).
        guard inCount > 0 else { return }
        let tap = inBuffers[inCount - 1]
        guard Int(tap.mNumberChannels) == tapChannels, let tapData = tap.mData else { return }
        let inData = tapData.assumingMemoryBound(to: Float.self)
        guard let (leftSamples, leftFrames) = samples(for: left, in: outBuffers, count: outCount) else { return }
        let rightTarget = right.flatMap { samples(for: $0, in: outBuffers, count: outCount) }

        var frames = min(Int(tap.mDataByteSize) / (tapChannels * MemoryLayout<Float>.size), leftFrames)
        if let rightTarget { frames = min(frames, rightTarget.1) }
        guard frames > 0 else { return }

        // Ramp towards the target gain over the buffer so slider moves don't click.
        let target = targetGain
        let step = (target - currentGain) / Float(frames)
        let soft = max(currentGain, target) > 1
        let rightOffset = tapChannels > 1 ? 1 : 0
        let leftStride = left.stride
        let rightStride = right?.stride ?? 0
        var gain = currentGain
        var peak: Float = 0

        for frame in 0..<frames {
            gain += step
            let l = inData[frame * tapChannels]
            let r = inData[frame * tapChannels + rightOffset]
            peak = max(peak, abs(l), abs(r))
            if let (rightSamples, _) = rightTarget {
                leftSamples[frame * leftStride] = limit(l * gain, soft: soft)
                rightSamples[frame * rightStride] = limit(r * gain, soft: soft)
            } else {
                leftSamples[frame * leftStride] = limit((l + r) * 0.5 * gain, soft: soft)
            }
        }
        currentGain = target
        inputPeakBits.store(peak.bitPattern, ordering: .relaxed)
        renderedCycleCount.add(1, ordering: .relaxed)
        if peak > 0 { lastAudibleCycleCount.store(cycle, ordering: .relaxed) }
    }
}
