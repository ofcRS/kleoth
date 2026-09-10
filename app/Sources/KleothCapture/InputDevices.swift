import AVFoundation
import CoreAudio
import Foundation
import os

/// One microphone as the user picks it: the CoreAudio device UID (stable
/// across reboots and reconnects, unlike the numeric `AudioDeviceID`) and the
/// name to show for it.
public struct InputDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The input devices CoreAudio knows about, and the one knob every capture
/// honours: `select(_:on:)` points an `AVAudioEngine`'s input node at a
/// specific device for the session and leaves the system default alone.
///
/// Listing is read-only and needs no microphone permission. The pill's
/// Microphone submenu, Settings and the three captures (`DictationCapture`,
/// `MicCapture`, `MicrophoneSource`) all go through here, so "the microphone
/// Kleoth uses" is one setting with one resolution rule.
///
/// Probed 2026-09-09 (WH-1000XM5 as the system input, 16 kHz): setting
/// `kAudioOutputUnitProperty_CurrentDevice` on the input node's unit BEFORE
/// its format is read made `inputFormat(forBus:)` report the built-in mic's
/// 48 kHz and the tap deliver frames at that rate — the selection is real,
/// not cosmetic. The system default input was untouched throughout.
public enum InputDevices {
    private static let log = Logger(subsystem: "dev.kleoth", category: "InputDevices")

    /// Every device with at least one input channel, in CoreAudio's order.
    public static func list() -> [InputDevice] {
        allDeviceIds()
            .filter { inputChannelCount($0) > 0 }
            .compactMap { id -> InputDevice? in
                guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                      let name = string(id, kAudioObjectPropertyName) else { return nil }
                return InputDevice(id: uid, name: name)
            }
    }

    /// The system input device's name, or nil when there is none.
    public static func defaultInputName() -> String? {
        defaultInputId().flatMap { string($0, kAudioObjectPropertyName) }
    }

    /// The name of the device a capture would open right now for `id`: the
    /// picked device when it is connected, else the system input — the same
    /// fallback `select(_:on:)` applies.
    public static func resolvedName(for id: String?) -> String? {
        if let id, !id.isEmpty, let device = deviceId(forUID: id) {
            return string(device, kAudioObjectPropertyName)
        }
        return defaultInputName()
    }

    /// Points `engine`'s input node at the device with `id` for this session.
    /// Call it BEFORE the input format is read or a tap is installed — the
    /// unit reports the new device's format only from then on.
    ///
    /// nil, an empty id, or a device that is not connected leaves the engine
    /// on the system input and returns false. A missing pick is never an
    /// error: a headset left in a bag must not stop a dictation.
    @discardableResult
    public static func select(_ id: String?, on engine: AVAudioEngine) -> Bool {
        guard let id, !id.isEmpty else { return false }
        guard let device = deviceId(forUID: id) else {
            log.notice("input device \(id, privacy: .public) is not connected — using the system input")
            return false
        }
        guard let unit = engine.inputNode.audioUnit else {
            log.error("input node has no audio unit — using the system input")
            return false
        }
        var target = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &target,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            log.error("could not select input device \(id, privacy: .public) (OSStatus \(status)) — using the system input")
            return false
        }
        return true
    }

    // MARK: - CoreAudio plumbing

    private static func deviceId(forUID uid: String) -> AudioObjectID? {
        allDeviceIds().first { inputChannelCount($0) > 0 && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func defaultInputId() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func allDeviceIds() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
