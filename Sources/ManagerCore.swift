import Cocoa
import CoreAudio
import Darwin

enum ControlFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): return text } }
}

extension Data {
    mutating func put<T: FixedWidthInteger>(_ number: T) {
        var n = number.littleEndian
        Swift.withUnsafeBytes(of: &n) { append(contentsOf: $0) }
    }
    func word(_ offset: Int, _ length: Int = 4) throws -> UInt32 {
        guard offset >= 0, offset + length <= count else { throw ControlFailure.message("OpenRGB 返回的数据不完整") }
        return (0..<length).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
}

final class RGBConnection {
    var fd: Int32 = -1
    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlFailure.message("无法创建 OpenRGB 本地连接") }
        do {
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(6742).bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            let connected = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw ControlFailure.message("OpenRGB 尚未运行，或本地 SDK 服务未开启") }
            var version = Data(); version.put(UInt32(6)); try send(40, version)
            guard try response(40).word(0) >= 6 else { throw ControlFailure.message("OpenRGB 版本不支持此管理器") }
            var access = Data(); access.put(UInt32(1 << 16)); try send(52, access)
            guard try response(53).word(0) & (1 << 16) != 0 else { throw ControlFailure.message("OpenRGB 尚未允许本机管理连接") }
        } catch { Darwin.close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func send(_ command: UInt32, _ body: Data = Data(), device: UInt32 = 0) throws {
        var packet = Data("ORGB".utf8)
        packet.put(device); packet.put(command); packet.put(UInt32(body.count)); packet.append(body)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let size = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw ControlFailure.message("发送 OpenRGB 指令失败") }
                offset += size
            }
        }
    }
    func receive(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let size = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw ControlFailure.message("OpenRGB 连接超时或已关闭") }
                offset += size
            }
        }
        return data
    }
    func response(_ command: UInt32, ack: Bool = false) throws -> Data {
        for _ in 0..<100 {
            let header = try receive(16)
            guard header.prefix(4) == Data("ORGB".utf8) else { throw ControlFailure.message("OpenRGB 协议校验失败") }
            let type = try header.word(8), size = try header.word(12)
            guard size <= 8 * 1024 * 1024 else { throw ControlFailure.message("OpenRGB 返回数据过大") }
            let body = try receive(Int(size))
            if ack && type == 10 {
                if try body.word(0) == command {
                    guard try body.word(4) == 0 else { throw ControlFailure.message("OpenRGB 拒绝执行指令 \(command)") }
                    return body
                }
            }
            if !ack && type == command { return body }
        }
        throw ControlFailure.message("未收到 OpenRGB 确认")
    }
    func profile(_ command: UInt32, _ name: String) throws {
        guard !name.contains("/"), !name.contains("\0") else { throw ControlFailure.message("配置名称不合法") }
        var payload = Data(name.utf8); payload.append(0)
        try send(command, payload); _ = try response(command, ack: true)
    }
    func effects() throws -> [String] {
        var payload = Data(); payload.put(UInt32(0)); try send(201, payload)
        let data = try response(201)
        let count = try data.word(8, 2)
        var offset = 10, names: [String] = []
        for _ in 0..<count {
            var fields: [String] = []
            for _ in 0..<2 {
                let length = Int(try data.word(offset, 2)); offset += 2
                guard length > 0, offset + length <= data.count else { throw ControlFailure.message("灯效状态数据不完整") }
                fields.append(String(data: data.subdata(in: offset..<(offset + length)).dropLast(), encoding: .utf8) ?? "")
                offset += length
            }
            guard offset < data.count else { throw ControlFailure.message("灯效状态数据不完整") }
            if data[offset] != 0 { names.append(fields[0]) }
            offset += 1
        }
        return names
    }
    func ready() throws -> Bool {
        try send(0)
        guard try response(0).word(0) > 0 else { return false }
        try send(200)
        let data = try response(200)
        let count = try data.word(4, 2)
        var offset = 6, found = false
        for _ in 0..<count {
            var isEffects = false
            for field in 0..<3 {
                let length = Int(try data.word(offset, 2)); offset += 2
                guard length > 0, offset + length <= data.count else { throw ControlFailure.message("插件状态数据不完整") }
                let value = String(data: data.subdata(in: offset..<(offset + length)).dropLast(), encoding: .utf8) ?? ""
                if field == 0 && value == "OpenRGB Effects Plugin" { found = true; isEffects = true }
                offset += length
            }
            let pluginIndex = try data.word(offset); offset += 8
            if isEffects && pluginIndex != 0 { throw ControlFailure.message("灯效插件顺序发生变化，请检查 OpenRGB 插件配置") }
        }
        guard found else { return false }
        _ = try effects()
        return true
    }
    func writeCaseColors(_ controller: [String: Any]) throws {
        guard let colors = controller["colors"] as? [UInt32], !colors.isEmpty, colors.count <= 65535,
              let vendor = controller["vendor"] as? String, let serial = controller["serial"] as? String,
              let description = controller["description"] as? String else { throw ControlFailure.message("机箱颜色数据不完整") }
        try send(0)
        let list = try response(0), count = Int(try list.word(0))
        var matches: [UInt32] = []
        for index in 0..<count {
            let id = try list.word(4 + index * 4)
            var version = Data(); version.put(UInt32(6))
            try send(1, version, device: id)
            let data = try response(1)
            var offset = 8, fields: [String] = []
            for _ in 0..<6 {
                let length = Int(try data.word(offset, 2)); offset += 2
                guard length > 0, offset + length <= data.count else { throw ControlFailure.message("控制器信息不完整") }
                fields.append(String(data: data.subdata(in: offset..<(offset + length)).dropLast(), encoding: .utf8) ?? "")
                offset += length
            }
            if fields[1] == vendor && fields[2] == description && fields[4] == serial { matches.append(id) }
        }
        guard matches.count == 1, let id = matches.first else { throw ControlFailure.message("无法唯一识别机箱灯光控制器") }
        // Direct mode holds its last color without a renderer or any audio capture.
        try send(1100, device: id); _ = try response(1100, ack: true)
        var payload = Data(); payload.put(UInt32(6 + colors.count * 4)); payload.put(UInt16(colors.count))
        for color in colors { payload.put(color) }
        try send(1050, payload, device: id); _ = try response(1050, ack: true)
    }
}

extension SpeakerVolume {
    func devices() throws -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try ids.withUnsafeMutableBytes { bytes in
            guard let p = bytes.baseAddress else { throw AudioFailure.message("没有音频设备") }
            try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, p))
        }
        return ids
    }
    func device(_ uid: String) throws -> AudioDeviceID {
        guard let id = try devices().first(where: { (try? self.uid($0)) == uid }) else { throw AudioFailure.message("未找到所需音频设备：\(uid == "BlackHole2ch_UID" ? "BlackHole 2ch" : "USB AUDIO")") }
        return id
    }
    func setDefault(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws {
        var addr = address(selector), value = id
        try checked(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value))
    }
    var selectors: [AudioObjectPropertySelector] { [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] }
    func routeSnapshot() throws -> [AudioDeviceID] {
        try selectors.map { try read(AudioObjectID(kAudioObjectSystemObject), $0, initial: AudioDeviceID(0)) }
    }
    func restoreRoute(_ ids: [AudioDeviceID]) throws {
        for (selector, id) in zip(selectors, ids) where id != 0 { try setDefault(id, selector) }
    }
    func outputChannels(_ id: AudioDeviceID) throws -> UInt32 {
        var addr = address(kAudioDevicePropertyStreamConfiguration, output: true), size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, Int(size)), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        try checked(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer))
        return UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + $1.mNumberChannels }
    }
    func configureMusic() throws {
        let speakerID = try speaker(), loopback = try device("BlackHole2ch_UID")
        var aggregate = (try? device(musicUID)) ?? 0
        if aggregate == 0 {
            let composition: [String: Any] = ["name": "OpenRGB 音乐同步", "uid": musicUID, "private": 0, "stacked": true, "master": speakerUID, "subdevices": [["uid": speakerUID, "drift": 0, "channels-in": 0, "channels-out": 2], ["uid": "BlackHole2ch_UID", "drift": 1, "channels-in": 0, "channels-out": 2]]]
            try checked(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate))
            Thread.sleep(forTimeInterval: 0.6)
        } else {
            let current: CFDictionary = try read(aggregate, kAudioAggregateDevicePropertyComposition, initial: [:] as CFDictionary)
            var dict = current as NSDictionary as? [String: Any] ?? [:]
            let subdevices = dict["subdevices"] as? [[String: Any]] ?? []
            let uids = Set(subdevices.compactMap { $0["uid"] as? String })
            if (dict["stacked"] as? NSNumber)?.boolValue != true || !uids.contains(speakerUID) || !uids.contains("BlackHole2ch_UID") {
                dict["stacked"] = true
                dict["master"] = speakerUID
                dict["subdevices"] = [["uid": speakerUID, "drift": 0, "channels-in": 0, "channels-out": 2], ["uid": "BlackHole2ch_UID", "drift": 1, "channels-in": 0, "channels-out": 2]]
                var updated = dict as CFDictionary, addr = address(kAudioAggregateDevicePropertyComposition)
                try withUnsafePointer(to: &updated) { pointer in
                    try checked(AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(MemoryLayout<CFDictionary>.size), UnsafeRawPointer(pointer)))
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        guard try outputChannels(aggregate) == 2 else { throw AudioFailure.message("双输出配置异常，未切换声音输出") }
        try setDefault(loopback, kAudioHardwarePropertyDefaultInputDevice)
        try setDefault(aggregate, kAudioHardwarePropertyDefaultOutputDevice)
        try setDefault(speakerID, kAudioHardwarePropertyDefaultSystemOutputDevice)
    }
    func configureDaily() throws {
        let id = try speaker()
        try setDefault(id, kAudioHardwarePropertyDefaultOutputDevice)
        try setDefault(id, kAudioHardwarePropertyDefaultSystemOutputDevice)
    }
}

struct ManagerSettings: Codable {
    var brightness: Double = 100
    var sensitivity: Double = 65
    var fps: Int = 60
    var dailyColor: UInt32 = 255
    var startupMode = "daily"
    var lastMode = "daily"
}

struct ManagerStatus {
    var mode = "unknown"
    var title = "正在检查状态…"
    var detail = ""
    var effects: [String] = []
    var connected = false
    var musicOutput = false
    var loopbackAvailable = false
    var inputReady = false
    var problem: String?
    var json: [String: Any] { ["mode": mode, "title": title, "detail": detail, "effects": effects, "connected": connected, "music_output": musicOutput, "blackhole_available": loopbackAvailable, "input_ready": inputReady, "problem": problem ?? ""] }
}

final class ManagerCore {
    let audio = SpeakerVolume()
    let home = FileManager.default.homeDirectoryForCurrentUser
    var root: URL { ManagerPaths.data }
    var profiles: URL { ManagerPaths.profiles }
    var settingsURL: URL { root.appendingPathComponent("manager-settings.json") }
    var loginURL: URL { home.appendingPathComponent("Library/LaunchAgents/local.openrgb.volume-control.plist") }
    var loginEnabled: Bool { FileManager.default.fileExists(atPath: loginURL.path) }
    func settings() -> ManagerSettings {
        if let data = try? Data(contentsOf: settingsURL), let value = try? JSONDecoder().decode(ManagerSettings.self, from: data) { return value }
        return ManagerSettings()
    }
    func saveSettings(_ settings: ManagerSettings) throws {
        guard (0...100).contains(settings.brightness), (1...500).contains(settings.sensitivity), [30, 60].contains(settings.fps), ["daily", "music", "last"].contains(settings.startupMode), ["music", "daily", "off"].contains(settings.lastMode) else { throw ControlFailure.message("设置数值超出范围") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
    func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw ControlFailure.message("灯光配置格式异常") }
        return value
    }
    func writeJSON(_ value: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    func connection(start: Bool = false) throws -> RGBConnection {
        if let connection = try? RGBConnection(), !start || (try? connection.ready()) == true { return connection }
        guard start else { throw ControlFailure.message("OpenRGB 未连接") }
        guard FileManager.default.fileExists(atPath: "/Applications/OpenRGB.app") else { throw ControlFailure.message("没有找到 OpenRGB 应用") }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.yourcompany.OpenRGB").filter {
            $0.bundleURL?.standardizedFileURL.path == "/Applications/OpenRGB.app"
        }
        guard instances.count <= 1 else { throw ControlFailure.message("检测到多个 OpenRGB 进程，请保留一个后重试") }
        if let instance = instances.first {
            func alive() -> Bool { Darwin.kill(instance.processIdentifier, 0) == 0 || errno == EPERM }
            // Opening an existing macOS app does not apply new --server arguments.
            // Let an app that is still launching finish before deciding it lacks a server.
            let grace = (instance.launchDate ?? Date()).addingTimeInterval(8)
            while Date() < grace && alive() {
                if let connection = try? RGBConnection(), (try? connection.ready()) == true { return connection }
                Thread.sleep(forTimeInterval: 0.4)
            }
            if (try? RGBConnection()) == nil && alive() {
                guard instance.terminate() else { throw ControlFailure.message("OpenRGB 正在运行但服务未开启，无法自动重新启动") }
                let stopDeadline = Date().addingTimeInterval(8)
                while alive() && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.1) }
                guard !alive() else { throw ControlFailure.message("OpenRGB 尚未退出，请关闭其对话框后重试") }
            }
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "/Applications/OpenRGB.app", "--args", "--startminimized", "--server", "--profile", "default"]
        try process.run(); process.waitUntilExit()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let connection = try? RGBConnection(), (try? connection.ready()) == true { return connection }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw ControlFailure.message("OpenRGB 本地服务未就绪。打开 OpenRGB，检查 SDK 服务器是否已开启。")
    }
    func status() -> ManagerStatus {
        var result = ManagerStatus()
        result.musicOutput = audio.isMusicOutput()
        result.loopbackAvailable = (try? audio.device("BlackHole2ch_UID")) != nil
        if let route = try? audio.routeSnapshot(), let input = try? audio.uid(route[1]) { result.inputReady = input == "BlackHole2ch_UID" }
        do {
            let connection = try connection()
            result.effects = try connection.effects()
            result.connected = true
            let hasAudio = result.effects.contains { $0.localizedCaseInsensitiveContains("audio") || $0.contains("音频") || $0.contains("音乐") }
            if hasAudio && result.musicOutput && result.inputReady {
                result.mode = "music"; result.title = "音乐同步已开启"; result.detail = "电脑音乐同步到机箱灯光，可用音量滑块独立调节音箱。"
            } else if result.effects.isEmpty && (try? audio.activeOutputUID()) == audio.speakerUID {
                result.mode = settings().lastMode == "off" ? "off" : "daily"
                result.title = result.mode == "off" ? "机箱灯光已关闭" : "普通灯光模式"
                result.detail = "声音直接输出到 USB 音箱，音乐效果未读取音频。"
            } else {
                result.mode = "mixed"; result.title = "灯效与声音设置未同步"; result.detail = "选择下方模式，可重新配置灯光与声音输出。"
            }
        } catch { result.title = "OpenRGB 未连接"; result.detail = "选择一个模式即可尝试启动并连接。"; result.problem = String(describing: error) }
        return result
    }
    func musicProfile(_ settings: ManagerSettings) throws -> [String: Any] {
        var data = try json(profiles.appendingPathComponent("音乐同步.json"))
        guard var plugins = data["plugins"] as? [String: Any], var plugin = plugins["OpenRGB Effects Plugin"] as? [String: Any], var effects = plugin["Effects"] as? [[String: Any]], let index = effects.firstIndex(where: { $0["EffectClassName"] as? String == "AudioSync" }), var custom = effects[index]["CustomSettings"] as? [String: Any], var audioSettings = custom["audio_settings"] as? [String: Any] else { throw ControlFailure.message("音乐同步配置缺失，请运行 scripts/configure.py 生成配置。") }
        effects[index]["Brightness"] = Int(settings.brightness)
        effects[index]["FPS"] = settings.fps
        effects[index]["AutoStart"] = true
        audioSettings["amplitude"] = Int(settings.sensitivity)
        custom["audio_settings"] = audioSettings
        effects[index]["CustomSettings"] = custom
        plugin["Effects"] = effects; plugins["OpenRGB Effects Plugin"] = plugin; data["plugins"] = plugins
        return data
    }
    func dailyProfile(_ settings: ManagerSettings, off: Bool) throws -> [String: Any] {
        var data = try json(profiles.appendingPathComponent("default.json"))
        let identity = try DeviceConfiguration.load().controller
        guard let controllers = data["controllers"] as? [[String: Any]] else { throw ControlFailure.message("default.json 中没有控制器") }
        let matches = controllers.filter { identity.matches($0) }
        guard matches.count == 1, var controller = matches.first, var modes = controller["modes"] as? [[String: Any]], let index = modes.firstIndex(where: { $0["name"] as? String == "Direct" }), let leds = controller["colors"] as? [Any], !leds.isEmpty else { throw ControlFailure.message("无法唯一匹配支持 Direct 模式的机箱控制器，请重新配置本机设备") }
        let scale = off ? 0 : settings.brightness / 100
        var color: UInt32 = 0
        for channel in 0..<3 {
            let component = Double((settings.dailyColor >> (channel * 8)) & 255)
            let scaled = UInt32((component * scale).rounded())
            color |= scaled << (channel * 8)
        }
        modes[index].removeValue(forKey: "colors")
        modes[index]["brightness"] = modes[index]["brightness_max"] ?? 255
        controller["modes"] = modes; controller["active_mode"] = index
        controller["colors"] = Array(repeating: color, count: leds.count)
        data["controllers"] = [controller]
        data["plugins"] = ["OpenRGB Effects Plugin": ["Effects": [], "version": 2]]
        data["profile_name"] = off ? "管家-关灯" : "管家-普通灯光"
        return data
    }
    func apply(_ mode: String, settings requested: ManagerSettings? = nil) throws -> ManagerStatus {
        guard ["music", "daily", "off"].contains(mode) else { throw ControlFailure.message("未知工作模式") }
        var settings = requested ?? self.settings()
        guard (0...100).contains(settings.brightness), (1...500).contains(settings.sensitivity), [30, 60].contains(settings.fps) else { throw ControlFailure.message("参数超出可用范围") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockFD = Darwin.open(root.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw ControlFailure.message("无法创建控制锁") }
        defer { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ControlFailure.message("正在切换模式，请稍后再试") }
        let prepared = try (mode == "music" ? musicProfile(settings) : dailyProfile(settings, off: mode == "off"))
        _ = try audio.speaker()
        if mode == "music" { _ = try audio.device("BlackHole2ch_UID") }
        let connection = try connection(start: true)
        let beforeRoute = try audio.routeSnapshot()
        let snapshot = "manager-transaction-" + UUID().uuidString
        try connection.profile(151, snapshot)
        let profile = mode == "music" ? "音乐同步" : mode == "off" ? "管家-关灯" : "管家-普通灯光"
        let target = profiles.appendingPathComponent(profile + ".json")
        let beforeProfile = try? Data(contentsOf: target)
        do {
            try writeJSON(prepared, target)
            if mode == "music" {
                try audio.configureMusic()
                try connection.profile(152, profile)
            } else {
                try connection.profile(152, profile)
                guard let controllers = prepared["controllers"] as? [[String: Any]], let controller = controllers.first else { throw ControlFailure.message("机箱配置缺失") }
                try connection.writeCaseColors(controller)
                try audio.configureDaily()
            }
            let active = try connection.effects()
            let hasAudio = active.contains { $0.localizedCaseInsensitiveContains("audio") || $0.contains("音频") || $0.contains("音乐") }
            let route = try audio.routeSnapshot()
            let inputUID = try audio.uid(route[1]), outputUID = try audio.uid(route[0])
            let valid = mode == "music" ? (hasAudio && outputUID == audio.musicUID && inputUID == "BlackHole2ch_UID") : (active.isEmpty && outputUID == audio.speakerUID)
            guard valid else { throw ControlFailure.message("模式切换未通过校验") }
            settings.lastMode = mode
            try saveSettings(settings)
        } catch {
            var rollbackErrors: [String] = []
            do {
                if let beforeProfile { try beforeProfile.write(to: target, options: .atomic) }
                else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            } catch { rollbackErrors.append("配置文件") }
            do { try audio.restoreRoute(beforeRoute) } catch { rollbackErrors.append("声音输出") }
            do { try connection.profile(152, snapshot) } catch { rollbackErrors.append("灯光模式") }
            if rollbackErrors.isEmpty { try? connection.profile(153, snapshot) }
            if !rollbackErrors.isEmpty { throw ControlFailure.message("\(error)。未能完整恢复：\(rollbackErrors.joined(separator: "、"))；恢复配置保留为 \(snapshot)。") }
            throw error
        }
        try? connection.profile(153, snapshot)
        return status()
    }
    func setLogin(_ enabled: Bool) throws {
        if enabled {
            try FileManager.default.createDirectory(at: loginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data: [String: Any] = ["Label": "local.openrgb.volume-control", "ProgramArguments": ["/usr/bin/open", home.appendingPathComponent("Applications/OpenRGB Volume.app").path, "--args", "--background"], "RunAtLoad": true, "ProcessType": "Interactive"]
            try PropertyListSerialization.data(fromPropertyList: data, format: .xml, options: 0).write(to: loginURL, options: .atomic)
        } else if loginEnabled { try FileManager.default.removeItem(at: loginURL) }
    }
    func startup() throws -> ManagerStatus {
        let prefs = settings()
        return try apply(prefs.startupMode == "last" ? prefs.lastMode : prefs.startupMode)
    }
}
