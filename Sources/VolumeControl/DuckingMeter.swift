import CoreAudio
import Foundation

/// Runs the DuckMeter helper (see Sources/DuckMeter) to learn how far macOS currently lowers apps on a device for a
/// call. The helper plays an inaudible tone, so it only runs while the level is on screen.
@MainActor
final class DuckingMeter {
    /// The current factor, smoothed (1 = not lowered), or nil while unknown.
    private(set) var level: Double?
    /// Called on each new reading.
    var onChange: () -> Void = {}

    private var process: Process?
    private var input: Pipe?
    private var device = AudioDeviceID.unknown
    private var buffer = Data()
    private var restartAttempts = 0
    private var readingsSinceStart = 0
    private var invalidReadings = 0

    /// The last level measured per device during this call, shown again straight away when measuring resumes
    /// (a new helper needs a few seconds for its first reading).
    private var remembered: [AudioDeviceID: Double] = [:]

    /// The helper's process, which plays and records like an app but isn't one.
    var helperPID: pid_t? { process?.processIdentifier }

    private static let helperURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("DuckMeter")

    /// Forgets the remembered levels, for when the call ends (the next call may lower apps by a different amount).
    func forgetLevels() {
        remembered.removeAll()
    }

    /// Measures on `device`, or stops with nil.
    func measure(on device: AudioDeviceID?) {
        let device = device ?? .unknown
        guard device != self.device else { return }
        stop()
        self.device = device
        restartAttempts = 0
        if device.isValid { start() }
    }

    private func start() {
        guard let uid = try? device.deviceUID(), FileManager.default.isExecutableFile(atPath: Self.helperURL.path) else {
            log.error("Can't measure call ducking: helper or device missing")
            return
        }
        let process = Process()
        process.executableURL = Self.helperURL
        process.arguments = [uid]
        let input = Pipe(), output = Pipe()
        process.standardInput = input  // Closing it (or our exit) stops the helper.
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }  // End of file: the helper ended.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, from: process) } }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(ended) } }
        }
        do {
            try process.run()
            self.process = process
            self.input = input
            readingsSinceStart = 0
            if let known = remembered[device] {
                level = known
                onChange()
            }
            log.notice("Measuring call ducking on device \(self.device)")
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            log.error("Couldn't start the ducking meter: \(error, privacy: .public)")
        }
    }

    /// Stops the helper; `device` stays what's wanted.
    private func stop() {
        output(of: process)?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
        invalidReadings = 0
        if level != nil {
            level = nil
            onChange()
        }
    }

    private func output(of process: Process?) -> FileHandle? {
        (process?.standardOutput as? Pipe)?.fileHandleForReading
    }

    private func received(_ data: Data, from process: Process) {
        guard process === self.process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            guard let reading = Double(line) else { continue }
            // A helper that keeps working for a while has earned new restarts.
            readingsSinceStart += 1
            if readingsSinceStart >= 10 { restartAttempts = 0 }
            // Nothing measured (e.g. no permission to capture) or nonsense: better unknown than a wrong number, but
            // one bad reading (a glitch) doesn't make it unknown.
            guard reading > 0.001, reading < 1.1 else {
                invalidReadings += 1
                if invalidReadings >= 3, level != nil {
                    level = nil
                    onChange()
                }
                continue
            }
            invalidReadings = 0
            // Smooth it, so the number doesn't flicker while macOS adjusts the lowering as people talk.
            level = min(1, level.map { $0 * 0.6 + reading * 0.4 } ?? reading)
            remembered[device] = level
            onChange()
        }
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        log.error("Ducking meter stopped (status \(ended.terminationStatus))")
        stop()
        // It stops when the device does (e.g. it changed format); try again a few times.
        guard restartAttempts < 3 else { return }
        restartAttempts += 1
        let device = self.device
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.process == nil, self.device == device, device.isValid else { return }
                self.start()
            }
        }
    }
}
