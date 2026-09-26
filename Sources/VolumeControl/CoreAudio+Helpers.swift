import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        let code = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        if chars.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "\(operation) failed ('\(String(decoding: chars, as: UTF8.self))')"
        }
        return "\(operation) failed (\(status))"
    }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check(status, "Reading '\(selector.fourCC)' of object \(self)")
        return result
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: T) throws -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
                  "Sizing '\(selector.fourCC)' of object \(self)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var result = [T](repeating: element, count: count)
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Reading '\(selector.fourCC)' of object \(self)")
        return Array(result.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String? {
        let value: CFString? = try read(selector, default: nil)
        return value as String?
    }

    // MARK: System

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID.unknown)
    }

    static func processObjects() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, element: AudioObjectID.unknown)
    }

    // MARK: Devices

    func deviceUID() throws -> String {
        guard let uid = try readString(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(operation: "Reading UID of device \(self)", status: kAudioHardwareUnspecifiedError)
        }
        return uid
    }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        (try? readArray(kAudioDevicePropertyStreams, scope: scope, element: AudioStreamID.unknown).count) ?? 0
    }

    /// Describes the device's sample rate and stream layout; changes when the device switches format.
    func formatSignature() -> String {
        let rate: Float64 = (try? read(kAudioDevicePropertyNominalSampleRate, default: 0)) ?? 0
        let outputs = (try? readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, element: AudioStreamID.unknown)) ?? []
        let formats = outputs.map { stream -> String in
            let format: AudioStreamBasicDescription = (try? stream.read(kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
            return "\(format.mChannelsPerFrame)ch@\(format.mSampleRate)"
        }
        let inputs = streamCount(scope: kAudioObjectPropertyScopeInput)
        return "\(rate)Hz out[\(formats.joined(separator: ","))] in\(inputs)"
    }

    /// The real devices this one plays to: itself, or for an aggregate device (a Multi-Output device, or the private
    /// one voice processing wraps around a call's microphone and speaker) its active sub-devices that have outputs.
    func playbackDevices() -> [AudioDeviceID] {
        let transport: UInt32 = (try? read(kAudioDevicePropertyTransportType, default: 0)) ?? 0
        guard transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate else {
            return streamCount(scope: kAudioObjectPropertyScopeOutput) > 0 ? [self] : []
        }
        let subDevices = (try? readArray(kAudioAggregateDevicePropertyActiveSubDeviceList, element: AudioDeviceID.unknown)) ?? []
        return subDevices.filter { $0.streamCount(scope: kAudioObjectPropertyScopeOutput) > 0 }
    }

    /// Zero-based output channel indexes the device uses for stereo left/right.
    func preferredStereoChannels() -> (left: Int, right: Int) {
        let channels = (try? readArray(kAudioDevicePropertyPreferredChannelsForStereo,
                                       scope: kAudioObjectPropertyScopeOutput,
                                       element: UInt32(0))) ?? []
        guard channels.count == 2, channels[0] > 0, channels[1] > 0 else { return (0, 1) }
        return (Int(channels[0]) - 1, Int(channels[1]) - 1)
    }

    /// Exempts this process's audio on the device from "ducking": the way calling apps (FaceTime, and anything
    /// else using voice processing) turn every other app down during a call, by up to 15 dB.
    ///
    /// What we play is other apps' audio, including the call itself. Without this, a FaceTime call routed through
    /// us is turned down by FaceTime's own ducking. This is the private `kAudioDevicePropertyProcessDuckOptOut`,
    /// which macOS uses for the same purpose (in-call speech); it only affects this process.
    func setDuckingOptOut(_ optOut: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(0x6E6F646B /* 'nodk' */, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(self, &address) else { return false }
        var value: UInt32 = optOut ? 1 : 0
        return AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Channel count of each buffer the device's IO proc receives for `scope`, in order.
    func bufferChannelCounts(scope: AudioObjectPropertyScope) -> [Int] {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, list) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    // MARK: Listeners

    /// Calls `handler` on the main queue whenever the property changes, until the listener is removed.
    func addListener(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ handler: @escaping () -> Void) -> PropertyListener? {
        PropertyListener(object: self, address: AudioObjectPropertyAddress(selector, scope: scope), handler: handler)
    }
}

/// Keeps a Core Audio property listener registered until `remove()` is called.
///
/// Uses the C callback API with a numeric ID as client data. (Swift closures passed to the block-based API are
/// re-bridged on every call, so they can never be removed, and an ID can't dangle like an object pointer.)
final class PropertyListener {
    private static let lock = NSLock()
    private static var handlers: [Int: () -> Void] = [:]
    private static var nextID = 1

    private static let callback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        let id = Int(bitPattern: clientData)
        lock.lock()
        let handler = handlers[id]
        lock.unlock()
        if let handler { DispatchQueue.main.async(execute: handler) }
        return noErr
    }

    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let id: Int
    private var removed = false

    fileprivate init?(object: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        Self.lock.lock()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        Self.lock.unlock()

        self.object = object
        self.address = address
        guard AudioObjectAddPropertyListener(object, &self.address, Self.callback, UnsafeMutableRawPointer(bitPattern: id)) == noErr else {
            Self.unregister(id)
            return nil
        }
    }

    private static func unregister(_ id: Int) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    func remove() {
        guard !removed else { return }
        removed = true
        AudioObjectRemovePropertyListener(object, &address, Self.callback, UnsafeMutableRawPointer(bitPattern: id))
        Self.unregister(id)
    }

    deinit { remove() }
}

extension UInt32 {
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
