import Cocoa
import ApplicationServices
import CoreAudio

final class ManagerDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class ManagerApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let core = ManagerCore()
    var audio: SpeakerVolume { core.audio }
    let worker = DispatchQueue(label: "local.openrgb.manager", qos: .utility)
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menuSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let menuPercent = NSTextField(labelWithString: "")
    let menuStatus = NSMenuItem(title: "正在检查…", action: nil, keyEquivalent: "")
    let muteItem = NSMenuItem(title: "静音音箱", action: #selector(toggleMute), keyEquivalent: "")
    let keysItem = NSMenuItem(title: "启用键盘音量键…", action: #selector(authorizeKeys), keyEquivalent: "")
    var modeItems: [String: NSMenuItem] = [:]
    var modeButtons: [String: NSButton] = [:]
    var managedControls: [NSControl] = []
    var window: NSWindow!
    let headline = NSTextField(labelWithString: "正在检查状态…")
    let detail = NSTextField(wrappingLabelWithString: "")
    let health = NSTextField(wrappingLabelWithString: "")
    let feedback = NSTextField(wrappingLabelWithString: "普通灯光的颜色、亮度自动应用；音乐参数调整后，点“应用灯光设置”。")
    let volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let volumePercent = NSTextField(labelWithString: "")
    let muteButton = NSButton(checkboxWithTitle: "静音", target: nil, action: nil)
    let brightness = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let sensitivity = NSSlider(value: 65, minValue: 1, maxValue: 200, target: nil, action: nil)
    let brightnessLabel = NSTextField(labelWithString: "100%")
    let sensitivityLabel = NSTextField(labelWithString: "65")
    let fps = NSPopUpButton(frame: .zero, pullsDown: false)
    let color = NSColorWell()
    let login = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
    let startup = NSPopUpButton(frame: .zero, pullsDown: false)
    let permissionButton = NSButton(title: "启用音量键…", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var timer: Timer?
    var busy = false
    var polling = false
    var nextPoll = Date.distantPast
    var current = ManagerStatus()
    var prefs = ManagerSettings()
    var lastVolumeError: String?
    var dailyPreview: DispatchWorkItem?
    var recoveryAfter = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        let own = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.openrgb.volume-control").first(where: { $0.processIdentifier != own }) {
            other.activate(options: [])
            NSApp.terminate(nil); return
        }
        prefs = core.settings()
        makeMenu(); makeWindow(); fillSettings(); startKeysIfAuthorized(); refreshVolume()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshVolume()
            self.startKeysIfAuthorized()
            if Date() >= self.nextPoll { self.pollStatus() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        if CommandLine.arguments.contains("--background") {
            run("正在应用开机模式…", operation: { try self.core.startup() })
        } else {
            showWindow(); pollStatus()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // System logout must not be delayed by a network operation. The next login applies the saved mode.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    func text(_ string: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }
    func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 10) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = vertical ? .vertical : .horizontal
        result.alignment = vertical ? .leading : .centerY
        result.spacing = spacing
        result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }
    func fill(_ view: NSView, in parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
    func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        return b
    }
    func card(_ title: String, rows: [NSView]) -> NSView {
        let titleView = text(title, size: 13, weight: .semibold)
        let content = stack([titleView] + rows, vertical: true, spacing: 10)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16), content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16), content.topAnchor.constraint(equalTo: box.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14)])
        for row in rows { fill(row, in: content) }
        return box
    }
    func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField) -> NSView {
        let label = text(title)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel(title)
        return stack([label, slider, value])
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 810), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "机箱控制台"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ManagerWindow")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        window.contentView = scroll
        let document = ManagerDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let title = text("机箱控制台", size: 27, weight: .bold)
        let subtitle = text("灯光、音乐和音量，一个地方管理。", size: 13, secondary: true)
        let heading = stack([title, subtitle], vertical: true, spacing: 5)
        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        health.font = .systemFont(ofSize: 11)
        health.textColor = .secondaryLabelColor
        let live = stack([headline, detail, health], vertical: true, spacing: 6)
        [headline, detail, health].forEach { fill($0, in: live) }
        let modes: [(String, String, String)] = [("music", "音乐同步", "waveform"), ("daily", "普通灯光", "lightbulb"), ("off", "关灯", "power")]
        var buttons: [NSView] = []
        for (mode, name, symbol) in modes {
            let b = button(name, #selector(selectMode(_:)), symbol: symbol)
            b.identifier = NSUserInterfaceItemIdentifier(mode)
            b.setButtonType(.pushOnPushOff)
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            modeButtons[mode] = b; managedControls.append(b); buttons.append(b)
        }
        let modeRow = stack(buttons, spacing: 10)
        modeRow.distribution = .fillEqually
        let modeHelp = text("普通灯光和关灯会停止读取音乐；声音仍正常播放。", size: 11, secondary: true)
        let modeSection = stack([live, modeRow, modeHelp], vertical: true, spacing: 12)
        [live, modeRow, modeHelp].forEach { fill($0, in: modeSection) }
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged(_:)); volumeSlider.isContinuous = true
        muteButton.target = self; muteButton.action = #selector(toggleMute)
        let volumeRow = sliderRow("音箱音量", volumeSlider, volumePercent)
        let volumeBox = card("声音", rows: [stack([volumeRow, muteButton])])
        volumeRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for slider in [brightness, sensitivity] { slider.target = self; slider.action = #selector(parametersChanged); slider.isContinuous = true; managedControls.append(slider) }
        brightness.isContinuous = false
        brightness.action = #selector(dailyParameterChanged)
        sensitivity.maxValue = max(200, prefs.sensitivity)
        fps.addItems(withTitles: ["30 FPS · 省资源", "60 FPS · 更流畅"])
        fps.target = self; fps.action = #selector(parametersChanged)
        color.target = self; color.action = #selector(dailyParameterChanged)
        color.widthAnchor.constraint(equalToConstant: 55).isActive = true
        color.heightAnchor.constraint(equalToConstant: 27).isActive = true
        color.setAccessibilityLabel("普通灯光颜色")
        managedControls += [fps, color]
        let extras = stack([text("音乐刷新率"), fps, NSView(), text("普通灯光颜色"), color])
        let apply = button("应用灯光设置", #selector(applySettings), symbol: "checkmark")
        managedControls.append(apply)
        let hint = text("普通灯光的颜色、亮度自动应用。", size: 11, secondary: true)
        let lightBox = card("灯光", rows: [sliderRow("亮度", brightness, brightnessLabel), sliderRow("音乐灵敏度", sensitivity, sensitivityLabel), extras, stack([hint, NSView(), apply])])
        login.target = self; login.action = #selector(saveStartup)
        startup.addItems(withTitles: ["普通灯光", "音乐同步", "上次模式"])
        startup.target = self; startup.action = #selector(saveStartup)
        managedControls += [login, startup]
        let launchRow = stack([login, NSView(), text("启动模式"), startup])
        let launchHint = text("下次登录按所选模式启动；关闭窗口后，菜单栏仍可使用。", size: 11, secondary: true)
        let launchBox = card("开机与后台", rows: [launchRow, launchHint])
        permissionButton.target = self; permissionButton.action = #selector(authorizeKeys); permissionButton.bezelStyle = .rounded
        let refresh = button("检查状态", #selector(checkStatus), symbol: "arrow.clockwise")
        let openRGB = button("打开 OpenRGB", #selector(openOpenRGB))
        let help = button("使用说明", #selector(openHelp))
        let tools = stack([refresh, openRGB, help, NSView(), permissionButton], spacing: 8)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        feedback.font = .systemFont(ofSize: 12)
        feedback.textColor = .secondaryLabelColor
        let notice = stack([spinner, feedback])
        let privacy = text("音乐同步使用 BlackHole 虚拟音频，macOS 会显示音频输入指示。普通模式停止读取；系统可能短暂显示“最近使用”。", size: 11, secondary: true)
        let content = stack([heading, modeSection, volumeBox, lightBox, launchBox, tools, notice, privacy], vertical: true, spacing: 16)
        document.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22), content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)])
        for row in content.arrangedSubviews { fill(row, in: content) }
    }
    func makeMenu() {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: key); i.target = self; menu.addItem(i); return i
        }
        _ = item("打开机箱控制台…", #selector(showWindow), key: "o")
        menuStatus.isEnabled = false; menu.addItem(menuStatus); menu.addItem(.separator())
        for (mode, title) in [("music", "音乐同步"), ("daily", "普通灯光 · 停止音频读取"), ("off", "关闭机箱灯光")] {
            let i = item(title, #selector(menuMode(_:))); i.representedObject = mode; modeItems[mode] = i
        }
        menu.addItem(.separator())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 48))
        menuSlider.frame = NSRect(x: 16, y: 12, width: 206, height: 24)
        menuSlider.target = self; menuSlider.action = #selector(volumeChanged(_:)); menuSlider.isContinuous = true
        menuSlider.setAccessibilityLabel("USB AUDIO 音箱音量")
        menuPercent.frame = NSRect(x: 230, y: 15, width: 52, height: 20)
        container.addSubview(menuSlider); container.addSubview(menuPercent)
        let viewItem = NSMenuItem(); viewItem.view = container; menu.addItem(viewItem)
        muteItem.target = self; menu.addItem(muteItem)
        keysItem.target = self; menu.addItem(keysItem)
        menu.addItem(.separator())
        _ = item("退出并恢复普通模式", #selector(quitApp), key: "q")
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("机箱控制台")
    }
    func fillSettings() {
        brightness.doubleValue = prefs.brightness; sensitivity.doubleValue = prefs.sensitivity
        fps.selectItem(at: prefs.fps == 30 ? 0 : 1)
        color.color = NSColor(srgbRed: Double(prefs.dailyColor & 255) / 255, green: Double((prefs.dailyColor >> 8) & 255) / 255, blue: Double((prefs.dailyColor >> 16) & 255) / 255, alpha: 1)
        login.state = core.loginEnabled ? .on : .off
        startup.selectItem(at: ["daily", "music", "last"].firstIndex(of: prefs.startupMode) ?? 0)
        parametersChanged()
    }
    func requestedSettings() -> ManagerSettings {
        var result = prefs
        result.brightness = brightness.doubleValue.rounded(); result.sensitivity = sensitivity.doubleValue.rounded()
        result.fps = fps.indexOfSelectedItem == 0 ? 30 : 60
        if let rgb = color.color.usingColorSpace(.sRGB) {
            let r = UInt32((min(1, max(0, rgb.redComponent)) * 255).rounded())
            let g = UInt32((min(1, max(0, rgb.greenComponent)) * 255).rounded())
            let b = UInt32((min(1, max(0, rgb.blueComponent)) * 255).rounded())
            result.dailyColor = r | (g << 8) | (b << 16)
        }
        result.startupMode = ["daily", "music", "last"][max(0, startup.indexOfSelectedItem)]
        return result
    }
    @objc func parametersChanged() {
        brightnessLabel.stringValue = "\(Int(brightness.doubleValue.rounded()))%"
        sensitivityLabel.stringValue = "\(Int(sensitivity.doubleValue.rounded()))"
    }
    @objc func dailyParameterChanged() {
        parametersChanged()
        dailyPreview?.cancel()
        guard current.mode == "daily" else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current.mode == "daily" else { return }
            if self.busy { self.dailyParameterChanged(); return }
            self.switchMode("daily")
        }
        dailyPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); nextPoll = .distantPast
    }
    func menuWillOpen(_ menu: NSMenu) { refreshVolume(); pollStatus() }
    @objc func checkStatus() { pollStatus(force: true) }
    func pollStatus(force: Bool = false) {
        guard !busy, !polling else { return }
        polling = true
        nextPoll = Date().addingTimeInterval(window.isVisible ? 5 : 30)
        worker.async {
            let value = self.core.status()
            DispatchQueue.main.async {
                self.polling = false
                if !self.busy { self.display(value) }
                if force && !self.busy { self.feedback.stringValue = value.problem ?? "状态检查完成。" }
                if !self.busy && !value.connected && Date() >= self.recoveryAfter {
                    self.recoveryAfter = Date().addingTimeInterval(60)
                    self.run("正在恢复 OpenRGB 连接和上次模式…", showError: false, operation: {
                        try self.core.apply(self.core.settings().lastMode)
                    })
                }
            }
        }
    }
    func display(_ value: ManagerStatus) {
        current = value; headline.stringValue = value.title; detail.stringValue = value.detail
        headline.textColor = value.connected && value.mode != "mixed" ? .labelColor : .systemOrange
        health.stringValue = "灯光服务：\(value.connected ? "已连接" : "未连接")  ·  声音：\(value.musicOutput ? "音乐双输出" : "普通输出")  ·  虚拟音频：\(value.loopbackAvailable ? "就绪" : "未找到")"
        menuStatus.title = value.title
        for (mode, b) in modeButtons { b.state = value.mode == mode ? .on : .off }
        for (mode, i) in modeItems { i.state = value.mode == mode ? .on : .off }
        statusItem.button?.toolTip = "机箱控制台 · \(value.title)"
        refreshVolume()
    }
    func setBusy(_ value: Bool) {
        busy = value
        for control in managedControls { control.isEnabled = !value }
        for item in modeItems.values { item.isEnabled = !value }
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    func run(_ message: String, showError: Bool = true, operation: @escaping () throws -> ManagerStatus, completion: (() -> Void)? = nil) {
        guard !busy else { return }
        setBusy(true); feedback.stringValue = message; feedback.textColor = .secondaryLabelColor
        worker.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                self.setBusy(false)
                switch result {
                case .success(let value):
                    self.prefs = self.core.settings()
                    self.display(value)
                    self.feedback.stringValue = "已完成：\(value.title)。"
                    completion?()
                case .failure(let error):
                    self.feedback.stringValue = "操作未完成：\(error)"
                    self.feedback.textColor = .systemRed
                    if showError { self.showWindow() }
                }
                self.nextPoll = .distantPast
            }
        }
    }
    func switchMode(_ mode: String) {
        let requested = requestedSettings()
        run("正在切换灯光与声音…", operation: { try self.core.apply(mode, settings: requested) })
    }
    @objc func selectMode(_ sender: NSButton) { if let mode = sender.identifier?.rawValue { switchMode(mode) } }
    @objc func menuMode(_ sender: NSMenuItem) { if let mode = sender.representedObject as? String { switchMode(mode) } }
    @objc func applySettings() {
        guard ["music", "daily", "off"].contains(current.mode) else { feedback.stringValue = "请先选择音乐同步、普通灯光或关灯。"; return }
        switchMode(current.mode)
    }
    @objc func saveStartup() {
        guard !busy else { return }
        // Startup controls must not silently save un-applied LED slider edits.
        var updated = core.settings()
        updated.startupMode = ["daily", "music", "last"][max(0, startup.indexOfSelectedItem)]
        let enabled = login.state == .on
        let previous = core.settings(), wasEnabled = core.loginEnabled
        do {
            try core.setLogin(enabled)
            try core.saveSettings(updated)
            prefs = updated
            feedback.stringValue = enabled ? "已保存开机设置，下次登录生效。" : "已关闭登录启动，当前运行不受影响。"
            feedback.textColor = .secondaryLabelColor
        } catch {
            try? core.setLogin(wasEnabled); try? core.saveSettings(previous)
            login.state = wasEnabled ? .on : .off
            startup.selectItem(at: ["daily", "music", "last"].firstIndex(of: previous.startupMode) ?? 0)
            feedback.stringValue = "保存失败：\(error)"; feedback.textColor = .systemRed
        }
    }
    @objc func openOpenRGB() {
        run("正在打开 OpenRGB…", operation: {
            let status = self.core.status()
            return status.connected ? status : try self.core.apply(self.core.settings().lastMode)
        }, completion: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/OpenRGB.app")) })
    }
    @objc func openHelp() { NSWorkspace.shared.open(core.root.appendingPathComponent("使用说明.txt")) }
    @objc func quitApp() {
        run("正在恢复普通模式后退出…", operation: { try self.core.apply("daily") }, completion: { NSApp.terminate(nil) })
    }
    func refreshVolume() {
        do {
            let value = try audio.volume(), muted = try audio.muted(), enabled = audio.canControl()
            let percent = "\(Int((value * 100).rounded()))%"
            menuSlider.doubleValue = Double(value * 100); volumeSlider.doubleValue = Double(value * 100)
            menuSlider.isEnabled = enabled; volumeSlider.isEnabled = enabled
            menuPercent.stringValue = percent; volumePercent.stringValue = percent
            muteItem.isEnabled = enabled; muteButton.isEnabled = enabled
            muteItem.state = muted ? .on : .off; muteButton.state = muted ? .on : .off
            statusItem.button?.title = muted ? " 静音" : " \(percent)"
            statusItem.button?.image = NSImage(systemSymbolName: muted || value == 0 ? "speaker.slash" : "speaker.wave.2", accessibilityDescription: "机箱控制台与音箱音量")
        } catch {
            menuSlider.isEnabled = false; volumeSlider.isEnabled = false
            muteItem.isEnabled = false; muteButton.isEnabled = false
            statusItem.button?.title = " 控制台"
            volumePercent.stringValue = "离线"
        }
        keysItem.title = tap == nil ? "启用键盘音量键…" : "键盘音量键已启用"
        keysItem.isEnabled = tap == nil
        permissionButton.title = tap == nil ? "启用音量键…" : "音量键已启用"
        permissionButton.isEnabled = tap == nil
    }
    func performVolume(_ action: () throws -> Void) {
        do { try action(); lastVolumeError = nil }
        catch { lastVolumeError = String(describing: error); feedback.stringValue = "音量操作失败：\(error)" }
        refreshVolume()
    }
    @objc func volumeChanged(_ sender: NSSlider) {
        guard audio.canControl() else { return }
        let value = Float32(sender.doubleValue / 100)
        performVolume { try audio.setVolume(value); try audio.setMuted(value == 0) }
    }
    @objc func toggleMute() {
        guard audio.canControl() else { return }
        performVolume { try audio.setMuted(!audio.muted()) }
    }
    @objc func authorizeKeys() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func startKeysIfAuthorized() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<ManagerApp>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = app.tap { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard app.audio.isMusicOutput(), let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let code = (key.data1 >> 16) & 0xffff
            guard [0, 1, 7].contains(code), (try? app.audio.volume()) != nil else { return Unmanaged.passUnretained(event) }
            if ((key.data1 >> 8) & 0xff) == 0x0a { app.mediaKey(code, fine: key.modifierFlags.contains([.option, .shift])) }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let port = tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }
    func mediaKey(_ code: Int, fine: Bool) {
        performVolume {
            if code == 7 { try audio.setMuted(!audio.muted()); return }
            let step: Float32 = fine ? 1 / 64 : 1 / 16
            let current = try audio.volume()
            let next = min(1, max(0, current + (code == 0 ? step : -step)))
            try audio.setVolume(next); try audio.setMuted(next == 0)
        }
    }
}

let args = CommandLine.arguments
let core = ManagerCore()
if args.contains("--list-audio") {
    do {
        let audio = core.audio
        let devices: [[String: Any]] = try audio.devices().compactMap { id in
            let channels = try audio.outputChannels(id)
            guard channels > 0 else { return nil }
            let name: CFString = try audio.read(id, kAudioObjectPropertyName, initial: "" as CFString)
            func writable(_ selector: AudioObjectPropertySelector) -> Bool {
                var address = audio.address(selector, output: true), value = DarwinBoolean(false)
                return AudioObjectIsPropertySettable(id, &address, &value) == noErr && value.boolValue
            }
            return ["name": name as String, "uid": try audio.uid(id), "output_channels": channels,
                    "volume_writable": writable(kAudioDevicePropertyVolumeScalar), "mute_writable": writable(kAudioDevicePropertyMute)]
        }
        let data = try JSONSerialization.data(withJSONObject: devices, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else if let index = args.firstIndex(of: "--control"), args.count > index + 1 {
    do {
        let command = args[index + 1]
        var result: [String: Any]
        if command == "status" { result = core.status().json }
        else if command == "startup" { result = try core.startup().json }
        else {
            var settings = core.settings()
            for (flag, setter) in [("--brightness", { (s: inout ManagerSettings, v: Double) in s.brightness = v }), ("--sensitivity", { (s: inout ManagerSettings, v: Double) in s.sensitivity = v })] {
                if let i = args.firstIndex(of: flag), args.count > i + 1, let value = Double(args[i + 1]) { setter(&settings, value) }
            }
            if let i = args.firstIndex(of: "--fps"), args.count > i + 1, let value = Int(args[i + 1]) { settings.fps = value }
            result = try core.apply(command, settings: settings).json
        }
        result["speaker_volume"] = try? core.audio.volume()
        result["speaker_muted"] = try? core.audio.muted()
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else if args.contains("--status") || args.contains("--self-test") {
    do {
        let audio = core.audio
        if args.contains("--self-test") {
            let before = try audio.volume(), muteBefore = try audio.muted(), outputBefore = try audio.activeOutputUID()
            do {
                try audio.setVolume(max(0, before - 0.025))
                let changed = try audio.volume()
                try audio.setVolume(before)
                let restored = try audio.volume()
                guard abs(changed - max(0, before - 0.025)) < 0.02, abs(restored - before) < 0.02,
                      try audio.muted() == muteBefore, try audio.activeOutputUID() == outputBefore else { throw AudioFailure.message("音量写入或恢复验证失败") }
                print("SELF_TEST_PASS before=\(before) lower=\(changed) restored=\(restored)")
            } catch { try? audio.setVolume(before); throw error }
        }
        print("output=\(try audio.activeOutputUID()) volume=\(try audio.volume()) muted=\(try audio.muted()) accessibility=\(AXIsProcessTrusted())")
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = ManagerApp()
    app.delegate = delegate
    app.run()
}
