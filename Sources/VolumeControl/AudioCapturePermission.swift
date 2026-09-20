import AppKit

/// The "System Audio Recording" privacy permission that process taps need. There's no public API to query it,
/// so this uses the TCC SPI (the same approach as Apple's sample code for process taps).
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// If a future macOS removes the SPI, assume access and let the system prompt when the tap is first read.
    private static var isAvailable: Bool {
        guard let tcc else { return false }
        return dlsym(tcc, "TCCAccessPreflight") != nil && dlsym(tcc, "TCCAccessRequest") != nil
    }

    static var status: Status {
        guard isAvailable else { return .authorized }
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(completion: @escaping (Bool) -> Void) {
        guard isAvailable, let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            completion(true)
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
