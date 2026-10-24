import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ControlFailure.message(message) }
}

// Exercise profile generation in temporary folders. No SDK/audio writes occur.
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
setenv("OPENRGB_MANAGER_DATA_DIR", temporary.path, 1)
setenv("OPENRGB_MANAGER_PROFILE_DIR", temporary.path, 1)
let core = ManagerCore()
do {
    _ = try DeviceConfiguration.load()
    throw ControlFailure.message("Missing device config should fail")
} catch let error as ControlFailure {
    try check(error.description.contains("尚未配置"), "Missing configuration diagnostic")
}
let identity: [String: Any] = ["vendor": "Example", "description": "Test controller", "serial": "TEST-ONLY"]
try core.writeJSON(["speakerUID": "TEST-SPEAKER", "controller": identity], temporary.appendingPathComponent("device-config.json"))
var controller = identity
controller["colors"] = [0, 0, 0]
controller["modes"] = [["name": "Direct", "brightness_max": 255, "colors": [255]]]
try core.writeJSON(["controllers": [controller]], temporary.appendingPathComponent("default.json"))
let original = try Data(contentsOf: temporary.appendingPathComponent("default.json"))
var settings = ManagerSettings()
settings.dailyColor = 0x80ff40
settings.brightness = 50
let profile = try core.dailyProfile(settings, off: false)
let output = (profile["controllers"] as! [[String: Any]])[0]
try check(output["colors"] as! [UInt32] == [0x408020, 0x408020, 0x408020], "Brightness must scale each channel")
let off = try core.dailyProfile(settings, off: true)
try check((off["controllers"] as! [[String: Any]])[0]["colors"] as! [UInt32] == [0, 0, 0], "Off must clear every LED")
let after = try Data(contentsOf: temporary.appendingPathComponent("default.json"))
try check(original == after, "Profile generation must preserve default.json")
try core.saveSettings(settings)
try check(core.settings().dailyColor == settings.dailyColor, "Settings round trip")
settings.fps = 120
do {
    try core.saveSettings(settings)
    throw ControlFailure.message("Invalid FPS should fail")
} catch let error as ControlFailure {
    try check(error.description.contains("超出范围"), "Invalid FPS diagnostic")
}
try core.writeJSON(["controllers": [controller, controller]], temporary.appendingPathComponent("default.json"))
do {
    _ = try core.dailyProfile(ManagerSettings(), off: false)
    throw ControlFailure.message("Ambiguous identity should fail")
} catch let error as ControlFailure {
    try check(error.description.contains("唯一匹配"), "Ambiguous identity diagnostic")
}
print("PASS: missing config, brightness, off, profile preservation, settings, validation, ambiguous controller")
