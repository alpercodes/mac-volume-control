// Measures how far macOS lowers ("ducks") other apps' audio on an output device during a call, for Volume Control.
//
// Volume Control can't measure it itself: it exempts its own playback from ducking, and that exemption covers a
// whole process on a device. And capturing an app's audio doesn't show it either, as a process tap receives the
// audio before ducking is applied (for a muted app; an unmuted one is captured ducked). So this separate process
// plays a tone to the device, inaudible (20 Hz at -80 dBFS), and captures it in its own share of the device's final
// mix: a global tap that excludes every other process, so nothing else is captured. It first opts out of ducking for
// a moment to learn the tone's level there unducked (the device's channel layout can change it), then measures
// with ducking. The ratio is the factor macOS currently lowers apps by, the same for every app on the device that
// isn't in the call.
//
// Usage: DuckMeter <device UID>. Prints the factor (1 = not lowered) every half second, and exits when its stdin
// closes (Volume Control quit or stopped it) or the device stops.

import CoreAudio
import Foundation
import Synchronization

let toneAmplitude: Float = 1e-4
/// Far below hearing at this level, and below any sample rate's limit (a high tone would fold back into the audible
/// range on a headset in call mode, which runs at 16 or 24 kHz). Half a second holds whole cycles.
let toneFrequency = 20.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("DuckMeter: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ operation: String) {
    if status != noErr { fail("\(operation) failed (\(status))") }
}

func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
              qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    var result = value
    _ = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, $0)
    }
    return result
}

/// Every audio process but this one, which the tap leaves out of the mix it captures.
func otherProcesses(than own: AudioObjectID) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { $0 != own }.sorted()
}

/// Only the tap's input is read: the device's own microphone stays off (opening it would switch AirPods to call
/// mode and need microphone permission). Same as Volume Control's `enableInputStreams`.
func disableDeviceInputs(of aggregate: AudioObjectID, for ioProcID: AudioDeviceIOProcID, deviceInputs: Int) {
    guard deviceInputs > 0 else { return }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size)
    let streamCount = Int(size) / MemoryLayout<AudioStreamID>.size
    let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!
    let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    let byteCount = max(flagsOffset + streamCount * MemoryLayout<UInt32>.stride, MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
    let usage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
    defer { usage.deallocate() }
    usage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    usage.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
    usage.storeBytes(of: UInt32(streamCount), toByteOffset: countOffset, as: UInt32.self)
    for index in 0..<streamCount {
        usage.storeBytes(of: index >= deviceInputs ? 1 : 0, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
    }
    address.mSelector = kAudioDevicePropertyIOProcStreamUsage
    check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(byteCount), usage), "Disabling device inputs")
}

guard CommandLine.arguments.count == 2 else { fail("usage: DuckMeter <device UID>") }
let deviceUID = CommandLine.arguments[1]

var device = AudioObjectID(kAudioObjectUnknown)
do {
    var uid = deviceUID as CFString
    device = withUnsafePointer(to: &uid) {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslateUIDToDevice, device,
             qualifier: $0, qualifierSize: UInt32(MemoryLayout<CFString>.size))
    }
}
guard device != kAudioObjectUnknown else { fail("no device \(deviceUID)") }
let sampleRate: Float64 = read(device, kAudioDevicePropertyNominalSampleRate, 0)
guard sampleRate > 0 else { fail("device has no sample rate") }
let phaseStep = 2 * Double.pi * toneFrequency / sampleRate

var pid = getpid()
let ownProcess: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyTranslatePIDToProcessObject, AudioObjectID(0),
                                     qualifier: &pid, qualifierSize: UInt32(MemoryLayout<pid_t>.size))
guard ownProcess != 0 else { fail("no process object") }

/// In-phase and quadrature sums of captured audio against the tone, and the number of frames: a lock-in
/// measurement of the tone's level that ignores everything at other frequencies.
struct Accumulator { var i = 0.0, q = 0.0, frames = 0, phase = 0.0 }

/// A tap on the device, read through a private aggregate device with the tap as its last input.
final class Capture {
    let description: CATapDescription
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var ioProc: AudioDeviceIOProcID?
    let sums = Mutex(Accumulator())

    init(_ description: CATapDescription, name: String) {
        self.description = description
        description.uuid = UUID()
        description.name = "Volume Control ducking meter"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        check(AudioHardwareCreateProcessTap(description, &tapID), "Creating \(name) tap")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Control ducking meter",
            kAudioAggregateDeviceUIDKey: "dev.alper.VolumeControl.DuckMeter.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating \(name) aggregate")
        check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { [unowned self] _, input, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let tap = buffers.last, let data = tap.mData?.assumingMemoryBound(to: Float.self),
                  tap.mNumberChannels > 0 else { return }
            let channels = Int(tap.mNumberChannels)
            let frames = Int(tap.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            self.sums.withLock { sums in
                var phase = sums.phase
                for frame in 0..<frames {
                    let sample = Double(data[frame * channels])
                    sums.i += sample * cos(phase)
                    sums.q += sample * sin(phase)
                    phase += phaseStep
                }
                sums.phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
                sums.frames += frames
            }
        }, "Creating \(name) IO proc")
        disableDeviceInputs(of: aggregateID, for: ioProc!, deviceInputs: deviceInputStreams)
        check(AudioDeviceStart(aggregateID, ioProc), "Starting \(name) capture")
    }

    /// The tone's amplitude since the last call, or nil if nothing was captured.
    func takeLevel() -> Double? {
        let taken = sums.withLock { sums -> Accumulator in
            let result = sums
            sums = Accumulator(phase: sums.phase)
            return result
        }
        guard taken.frames > 0 else { return nil }
        return 2 * (taken.i * taken.i + taken.q * taken.q).squareRoot() / Double(taken.frames)
    }

    func destroy() {
        if let ioProc { AudioDeviceStop(aggregateID, ioProc); AudioDeviceDestroyIOProcID(aggregateID, ioProc) }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
var streamsSize: UInt32 = 0
let deviceInputStreams = AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr
    ? Int(streamsSize) / MemoryLayout<AudioStreamID>.size : 0

// The tone, played straight to the device like any app's audio.
var tonePhase = 0.0
var toneProc: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&toneProc, device, nil) { _, _, _, output, _ in
    var frames = 0
    for buffer in UnsafeMutableAudioBufferListPointer(output) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
        let channels = Int(buffer.mNumberChannels)
        frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        var phase = tonePhase
        for frame in 0..<frames {
            let value = toneAmplitude * Float(sin(phase))
            for channel in 0..<channels { data[frame * channels + channel] = value }
            phase += phaseStep
        }
    }
    tonePhase = (tonePhase + Double(frames) * phaseStep).truncatingRemainder(dividingBy: 2 * .pi)
}, "Creating tone IO proc")

check(AudioDeviceStart(device, toneProc), "Starting tone")
var excluded = otherProcesses(than: ownProcess)
let mixed = Capture(CATapDescription(stereoGlobalTapButExcludeProcesses: excluded), name: "mix")

/// Exempts this process's audio on the device from ducking (the private 'nodk' property Volume Control uses too).
func setDuckingOptOut(_ optOut: Bool) {
    var address = AudioObjectPropertyAddress(mSelector: 0x6E6F646B /* 'nodk' */, mScope: kAudioObjectPropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = optOut ? 1 : 0
    check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value),
          "Setting the ducking opt-out")
}
setDuckingOptOut(true)

func cleanUp() {
    mixed.destroy()
}

// A new sample rate would change the tone under the measurement; the app starts a new meter.
var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(device, &rateAddress, DispatchQueue.main) { _, _ in
    let rate: Float64 = read(device, kAudioDevicePropertyNominalSampleRate, 0)
    if rate != sampleRate { cleanUp(); fail("sample rate changed") }
}

// Quit with the app: it holds the other end of stdin.
Thread.detachNewThread {
    while readLine() != nil {}
    cleanUp()
    exit(0)
}
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { cleanUp(); exit(0) }
termination.resume()

var idleReadings = 0
var ticks = 0
/// The tone's level in the mix without ducking, averaged over the calibration.
var unducked: [Double] = []
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    guard let level = mixed.takeLevel() else {
        idleReadings += 1
        if idleReadings >= 6 { cleanUp(); fail("device stopped") }
        return
    }
    idleReadings = 0
    ticks += 1
    // Half-second windows: 1 while the tone starts, 2–3 unducked, 4–5 while ducking ramps back in, then measure.
    switch ticks {
    case 2, 3:
        unducked.append(level)
        if ticks == 3 { setDuckingOptOut(false) }
    case 6...:
        let reference = unducked.reduce(0, +) / Double(unducked.count)
        print(String(format: "%.4f", reference > 0 ? level / reference : 0))
        fflush(stdout)
    default:
        break
    }

    // Keep processes that started since out of the capture.
    if ticks % 4 == 0 {
        let current = otherProcesses(than: ownProcess)
        if current != excluded {
            excluded = current
            mixed.description.processes = current
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value = mixed.description
            _ = withUnsafeMutablePointer(to: &value) {
                AudioObjectSetPropertyData(mixed.tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
        }
    }
}
RunLoop.main.run()
