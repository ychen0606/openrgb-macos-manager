import Cocoa
import CoreAudio
import ApplicationServices

enum AudioFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case let .message(value): return value } }
}

final class SpeakerVolume {
    let speakerUID = (try? DeviceConfiguration.load())?.speakerUID ?? ""
    let musicUID = "local.openrgb.music-sync.usb-audio"

    func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    func checked(_ result: OSStatus) throws {
        if result != noErr { throw AudioFailure.message("音频设备暂不可用（\(result)）") }
    }
    func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, output: Bool = false) throws -> T {
        var addr = address(selector, output: output)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try checked(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(pointer)))
        }
        return value
    }
    func uid(_ id: AudioObjectID) throws -> String {
        let value: CFString = try read(id, kAudioDevicePropertyDeviceUID, initial: "" as CFString)
        return value as String
    }
    func speaker() throws -> AudioDeviceID {
        guard !speakerUID.isEmpty else { throw AudioFailure.message("尚未配置音箱，请先运行 scripts/configure.py") }
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try ids.withUnsafeMutableBytes { bytes in
            guard let pointer = bytes.baseAddress else { throw AudioFailure.message("未找到音频设备") }
            try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, pointer))
        }
        guard let id = ids.first(where: { (try? uid($0)) == speakerUID }) else {
            throw AudioFailure.message("未连接配置中的音箱，请检查连接或重新运行配置工具")
        }
        return id
    }
    func activeOutputUID() throws -> String {
        let id: AudioDeviceID = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        return try uid(id)
    }
    func isMusicOutput() -> Bool { (try? activeOutputUID()) == musicUID }
    func canControl() -> Bool {
        guard let active = try? activeOutputUID() else { return false }
        return active == musicUID || active == speakerUID
    }
    func volume() throws -> Float32 {
        try read(speaker(), kAudioDevicePropertyVolumeScalar, initial: Float32(0), output: true)
    }
    func muted() throws -> Bool {
        let value: UInt32 = try read(speaker(), kAudioDevicePropertyMute, initial: UInt32(0), output: true)
        return value != 0
    }
    func write<T>(_ selector: AudioObjectPropertySelector, value: T) throws {
        let id = try speaker()
        var addr = address(selector, output: true)
        var settable = DarwinBoolean(false)
        try checked(AudioObjectIsPropertySettable(id, &addr, &settable))
        guard settable.boolValue else { throw AudioFailure.message("USB AUDIO 不支持此音量操作") }
        var copy = value
        try withUnsafePointer(to: &copy) { pointer in
            try checked(AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), UnsafeRawPointer(pointer)))
        }
    }
    func setVolume(_ value: Float32) throws {
        try write(kAudioDevicePropertyVolumeScalar, value: min(1, max(0, value)))
    }
    func setMuted(_ value: Bool) throws { try write(kAudioDevicePropertyMute, value: UInt32(value ? 1 : 0)) }
}
