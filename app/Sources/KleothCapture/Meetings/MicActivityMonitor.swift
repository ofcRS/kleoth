import CoreAudio
import Foundation
import KleothCore
import os

/// One process that runs audio input, as Core Audio reports it.
public struct MicClient: Sendable, Equatable, Hashable {
    public var pid: pid_t
    /// `kAudioProcessPropertyBundleID`; nil when Core Audio has none (a bare binary).
    public var bundleId: String?
    /// `proc_pidpath`; nil when unreadable.
    public var executablePath: String?

    public init(pid: pid_t, bundleId: String?, executablePath: String?) {
        self.pid = pid; self.bundleId = bundleId; self.executablePath = executablePath
    }
}

public enum MicActivityMonitorError: Error, Sendable {
    case listenerFailed(OSStatus)
}

/// Which processes hold the microphone right now (design §3.2.1).
///
/// The truth is `kAudioProcessPropertyIsRunningInput`, read on every re-read
/// — per-process `IsRunningInput` listeners register and never fire (Apple
/// forums 770348). Triggers: the system object's process-list listener and,
/// on each Process object, `IsRunning` + `Devices`; each schedules full
/// re-reads at `triggerRereads`. A backstop poll every `pollWhileHeld` s
/// while anything holds the mic, `pollIdle` s otherwise. `ServiceRestarted`
/// re-establishes every listener. Reading Process objects starts no IO and
/// shows no permission prompt.
public final class MicActivityMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kleoth.micactivity", qos: .utility)
    private let log = Logger(subsystem: "dev.kleoth", category: "MicActivity")
    // Everything below is touched only on `queue`.
    private var onChange: (@Sendable ([MicClient]) -> Void)?
    private var last: Set<MicClient> = []
    private var running = false
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var restartListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var rereadItems: [DispatchWorkItem] = []

    public init() {}

    /// Synchronous on the monitor's queue — never read it from inside `onChange`.
    public var isRunning: Bool { queue.sync { running } }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Reads

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let cf = value else { return nil }
        let string = cf.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    /// `proc_pidpath`. `PROC_PIDPATHINFO_MAXSIZE` (4 × MAXPATHLEN) is a macro
    /// Swift cannot see.
    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// One synchronous read of every process running input, this one excluded.
    public static func snapshot() -> [MicClient] {
        let me = ProcessInfo.processInfo.processIdentifier
        return processObjects().compactMap { object in
            guard readUInt32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            guard let rawPid = readUInt32(object, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(Int32(bitPattern: rawPid))
            guard pid > 0, pid != me else { return nil }
            return MicClient(pid: pid, bundleId: readString(object, kAudioProcessPropertyBundleID), executablePath: executablePath(of: pid))
        }
    }

    // MARK: - Lifecycle

    /// Installs the listeners and reads once; `onChange` gets the full set
    /// (sorted by pid) whenever it differs from the last one — at start only
    /// if something already holds the mic. Idempotent while running.
    ///
    /// `onChange` runs ON THE MONITOR'S QUEUE: hop (to the main actor, say)
    /// before touching the monitor — `isRunning`, `start` and `stop` are
    /// `queue.sync` and deadlock when called from inside the callback.
    public func start(onChange: @escaping @Sendable ([MicClient]) -> Void) throws {
        try queue.sync {
            guard !running else { return }
            self.onChange = onChange
            do {
                try installSystemListeners()
            } catch {
                removeAllListeners()
                self.onChange = nil
                throw error
            }
            running = true
            reread()
            schedulePoll()
        }
    }

    /// Removes every listener and timer; idempotent.
    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            removeAllListeners()
            pollTimer?.cancel(); pollTimer = nil
            rereadItems.forEach { $0.cancel() }; rereadItems = []
            last = []
            onChange = nil
        }
    }

    private func installSystemListeners() throws {
        var listAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
        let list: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.trigger() }
        let status = AudioObjectAddPropertyListenerBlock(Self.system, &listAddress, queue, list)
        guard status == noErr else { throw MicActivityMonitorError.listenerFailed(status) }
        systemListener = list
        var restartAddress = Self.address(kAudioHardwarePropertyServiceRestarted)
        let restart: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.serviceRestarted() }
        if AudioObjectAddPropertyListenerBlock(Self.system, &restartAddress, queue, restart) == noErr { restartListener = restart }
        refreshProcessListeners()
    }

    /// `IsRunning` + `Devices` on every Process object (the ones that fire).
    private func refreshProcessListeners() {
        let current = Set(Self.processObjects())
        for (object, block) in processListeners where !current.contains(object) {
            for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices] {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
            processListeners.removeValue(forKey: object)
        }
        for object in current where processListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.trigger() }
            var installed = false
            for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices] {
                var address = Self.address(selector)
                if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { installed = true }
            }
            if installed { processListeners[object] = block }
        }
    }

    private func removeAllListeners() {
        if let systemListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, systemListener)
        }
        if let restartListener {
            var address = Self.address(kAudioHardwarePropertyServiceRestarted)
            AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, restartListener)
        }
        systemListener = nil; restartListener = nil
        for (object, block) in processListeners {
            for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices] {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
        }
        processListeners = [:]
    }

    private func serviceRestarted() {
        guard running else { return }
        log.notice("coreaudiod restarted — re-establishing listeners")
        removeAllListeners()
        do {
            try installSystemListeners()
        } catch {
            // The backstop poll keeps working without listeners.
            log.error("re-establishing listeners failed: \(String(describing: error), privacy: .public)")
        }
        trigger()
    }

    /// A notification: full re-reads at `triggerRereads` (the list listener
    /// fires before the new process's flags are set).
    private func trigger() {
        guard running else { return }
        refreshProcessListeners()
        for delay in MeetingDetectionDefaults.triggerRereads {
            let item = DispatchWorkItem { [weak self] in self?.reread() }
            rereadItems.append(item)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
        if rereadItems.count > 16 { rereadItems.removeFirst(rereadItems.count - 16) }
    }

    private func reread() {
        guard running else { return }
        let now = Set(Self.snapshot())
        guard now != last else { return }
        last = now
        onChange?(Array(now).sorted { $0.pid < $1.pid })
        schedulePoll()
    }

    /// (Re)arms the backstop poll at the interval the current set calls for.
    private func schedulePoll() {
        pollTimer?.cancel()
        let interval = last.isEmpty ? MeetingDetectionDefaults.pollIdle : MeetingDetectionDefaults.pollWhileHeld
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.reread() }
        timer.resume()
        pollTimer = timer
    }
}
