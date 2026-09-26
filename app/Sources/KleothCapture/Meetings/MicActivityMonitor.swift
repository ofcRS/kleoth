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
/// on each Process object, `IsRunning` + `Devices`; they schedule full
/// re-reads at `triggerRereads` (coalesced). A backstop poll every `pollWhileHeld` s
/// while anything holds the mic, `pollIdle` s otherwise. `ServiceRestarted`
/// re-establishes every listener. Reading Process objects starts no IO and
/// shows no permission prompt.
///
/// Listeners are the function-pointer kind (`AudioObjectAddPropertyListener`
/// with one C proc and one context): `AudioObjectRemovePropertyListenerBlock`
/// called from Swift removed nothing on macOS 26 (probed 2026-09-26: the block
/// kept firing after the remove, which still returned `noErr`), so block
/// listeners leaked on `stop()` and stacked up on every restart.
public final class MicActivityMonitor: @unchecked Sendable {
    fileprivate enum Event: Sendable { case processList, process, serviceRestarted }

    fileprivate let queue: DispatchQueue
    private let log = Logger(subsystem: "dev.kleoth", category: "MicActivity")
    /// The listeners' client data: +1 for the monitor's life, the same pointer
    /// for every add and remove.
    private let context: Unmanaged<MicActivityListenerContext>
    // Everything below is touched only on `queue`.
    private var onChange: (@Sendable ([MicClient]) -> Void)?
    private var last: Set<MicClient> = []
    private var running = false
    private var listeningToProcessList = false
    private var listeningToRestarts = false
    private var processListeners: Set<AudioObjectID> = []
    private var pollTimer: DispatchSourceTimer?
    /// At most one leading and one trailing re-read pending (`scheduleRereads`).
    private var leadingReread: DispatchWorkItem?
    private var trailingReread: DispatchWorkItem?

    public init() {
        let queue = DispatchQueue(label: "dev.kleoth.micactivity", qos: .utility)
        let context = MicActivityListenerContext(queue: queue)
        self.queue = queue
        self.context = Unmanaged.passRetained(context)
        context.monitor = self
    }

    deinit {
        // Normally a no-op (`stop()` ran). A running monitor dropped by its
        // owner: nothing else holds `self` now, so the queue-only state is
        // safe to touch here.
        removeAllListeners()
        pollTimer?.cancel()
        leadingReread?.cancel(); trailingReread?.cancel()
        // A notification already inside the proc may still read the context:
        // release it well after the removes.
        let context = self.context
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { context.release() }
    }

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
    static func executablePath(of pid: pid_t) -> String? {
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
                try installListeners()
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
            leadingReread?.cancel(); leadingReread = nil
            trailingReread?.cancel(); trailingReread = nil
            last = []
            onChange = nil
        }
    }

    // MARK: - Listeners

    private var clientData: UnsafeMutableRawPointer { context.toOpaque() }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> OSStatus {
        var address = Self.address(selector)
        return AudioObjectAddPropertyListener(object, &address, micActivityListenerProc, clientData)
    }

    private func remove(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        AudioObjectRemovePropertyListener(object, &address, micActivityListenerProc, clientData)
    }

    private static let processSelectors = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices]

    private func installListeners() throws {
        let status = add(Self.system, kAudioHardwarePropertyProcessObjectList)
        guard status == noErr else { throw MicActivityMonitorError.listenerFailed(status) }
        listeningToProcessList = true
        listeningToRestarts = add(Self.system, kAudioHardwarePropertyServiceRestarted) == noErr
        refreshProcessListeners()
    }

    /// `IsRunning` + `Devices` on every Process object (the ones that fire).
    private func refreshProcessListeners() {
        let current = Set(Self.processObjects())
        for object in processListeners.subtracting(current) {
            for selector in Self.processSelectors { remove(object, selector) }
            processListeners.remove(object)
        }
        for object in current.subtracting(processListeners) {
            var installed = false
            for selector in Self.processSelectors where add(object, selector) == noErr { installed = true }
            if installed { processListeners.insert(object) }
        }
    }

    private func removeAllListeners() {
        if listeningToProcessList { remove(Self.system, kAudioHardwarePropertyProcessObjectList) }
        if listeningToRestarts { remove(Self.system, kAudioHardwarePropertyServiceRestarted) }
        listeningToProcessList = false; listeningToRestarts = false
        for object in processListeners {
            for selector in Self.processSelectors { remove(object, selector) }
        }
        processListeners = []
    }

    // MARK: - Notifications (on `queue`)

    fileprivate func notified(_ event: Event) {
        guard running else { return }
        switch event {
        case .serviceRestarted:
            log.notice("coreaudiod restarted — re-establishing listeners")
            removeAllListeners()
            do {
                try installListeners()
            } catch {
                // The backstop poll keeps working without listeners.
                log.error("re-establishing listeners failed: \(String(describing: error), privacy: .public)")
            }
        case .processList:
            refreshProcessListeners()
        case .process:
            break
        }
        scheduleRereads()
    }

    /// Full re-reads after a notification (the list listener fires before the
    /// new process's flags are set), coalesced: the FIRST `triggerRereads`
    /// offset is a leading re-read, skipped while one is pending; the LAST is a
    /// trailing one, pushed back by every notification — so a burst costs one
    /// re-read per leading interval plus one after it settles, not two per event.
    private func scheduleRereads() {
        let offsets = MeetingDetectionDefaults.triggerRereads
        guard let first = offsets.first, let lastOffset = offsets.last else { return }
        if leadingReread == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.leadingReread = nil
                self.reread()
            }
            leadingReread = item
            queue.asyncAfter(deadline: .now() + first, execute: item)
        }
        guard lastOffset > first else { return }
        trailingReread?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailingReread = nil
            self.reread()
        }
        trailingReread = item
        queue.asyncAfter(deadline: .now() + lastOffset, execute: item)
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

/// The listeners' client data. `monitor` is weak: the context outlives the
/// monitor briefly (see `deinit`).
private final class MicActivityListenerContext: @unchecked Sendable {
    let queue: DispatchQueue
    weak var monitor: MicActivityMonitor?
    init(queue: DispatchQueue) { self.queue = queue }
}

/// The one proc behind every listener. The HAL calls it on its own thread;
/// it only classifies the addresses and hops to the monitor's queue.
private let micActivityListenerProc: AudioObjectPropertyListenerProc = { _, count, addresses, clientData in
    guard let clientData else { return noErr }
    let context = Unmanaged<MicActivityListenerContext>.fromOpaque(clientData).takeUnretainedValue()
    var event = MicActivityMonitor.Event.process
    for index in 0..<Int(count) {
        switch addresses[index].mSelector {
        case kAudioHardwarePropertyServiceRestarted: event = .serviceRestarted
        case kAudioHardwarePropertyProcessObjectList where event != .serviceRestarted: event = .processList
        default: break
        }
    }
    let delivered = event
    context.queue.async { [weak monitor = context.monitor] in monitor?.notified(delivered) }
    return noErr
}
