import Foundation

enum ManagerPaths {
    static var data: URL {
        if let path = ProcessInfo.processInfo.environment["OPENRGB_MANAGER_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenRGB-Volume")
    }
    static var profiles: URL {
        if let path = ProcessInfo.processInfo.environment["OPENRGB_MANAGER_PROFILE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/OpenRGB/profiles")
    }
}

struct ControllerIdentity: Codable {
    let vendor: String
    let description: String
    let serial: String

    func matches(_ controller: [String: Any]) -> Bool {
        controller["vendor"] as? String == vendor &&
        controller["description"] as? String == description &&
        controller["serial"] as? String == serial
    }
}

struct DeviceConfiguration: Codable {
    let speakerUID: String
    let controller: ControllerIdentity

    static func load() throws -> DeviceConfiguration {
        let url = ManagerPaths.data.appendingPathComponent("device-config.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ControlFailure.message("尚未配置本机设备，请先运行 scripts/configure.py（参见 README）")
        }
        let config: DeviceConfiguration
        do { config = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ControlFailure.message("device-config.json 格式异常，请重新运行配置工具") }
        guard !config.speakerUID.isEmpty else { throw ControlFailure.message("尚未选择音箱设备") }
        return config
    }
}
