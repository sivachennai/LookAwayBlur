// LookAwayBlur — blurs all Mac screens when the AirPods say your head is turned away.
// v1: menu-bar app, hotkeys ⌃⌥Z = zero (facing screen), ⌃⌥X = panic clear + pause.
import Cocoa
import CoreMotion
import Carbon.HIToolbox

let BLUR_ON_DEG  = 40.0   // |delta yaw| above this → blur
let BLUR_OFF_DEG = 25.0   // |delta yaw| below this → clear (hysteresis)
let ON_DEBOUNCE  = 0.30   // seconds past threshold before blurring
let OFF_DEBOUNCE = 0.15
let WATCHDOG_S   = 1.5    // no motion sample for this long → clear + "no signal"
let DRIFT_TAU_S  = 90.0   // slow re-zero while facing screen and still

final class Overlay {
    var windows: [NSWindow] = []
    var shown = false
    init() { build(); NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in self.build() } }
    func build() {
        windows.forEach { $0.orderOut(nil) }; windows = []
        for s in NSScreen.screens {
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            v.autoresizingMask = [.width, .height]
            let dim = NSView(frame: v.bounds); dim.wantsLayer = true
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            dim.autoresizingMask = [.width, .height]
            v.addSubview(dim)
            w.contentView = v
            w.alphaValue = 0
            windows.append(w)
        }
        if shown { windows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() } }
    }
    func show() {
        guard !shown else { return }; shown = true
        windows.forEach { $0.alphaValue = 0; $0.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; self.windows.forEach { $0.animator().alphaValue = 1 } }
    }
    func hide() {
        guard shown else { return }; shown = false
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; self.windows.forEach { $0.animator().alphaValue = 0 } },
                                            completionHandler: { if !self.shown { self.windows.forEach { $0.orderOut(nil) } } })
    }
}

final class App: NSObject, NSApplicationDelegate, CMHeadphoneMotionManagerDelegate {
    let motion = CMHeadphoneMotionManager()
    let overlay = Overlay()
    var status: NSStatusItem!
    var zero: Double? = nil            // radians
    var enabled = true
    var lastYaw = 0.0, lastGyro = 0.0
    var stillSince: Date? = nil
    var pastOnSince: Date? = nil, belowOffSince: Date? = nil
    var lastSample = Date.distantPast
    var samples = 0
    var lastDriftTick = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Zero — I'm facing the screen  (⌃⌥Z)", action: #selector(zeroNow), keyEquivalent: "")
        menu.addItem(withTitle: "Pause / Resume  (⌃⌥X)", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Install Launch at Login", action: #selector(installLaunchAgent), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        status.menu = menu
        setIcon("👁 …")
        registerHotkeys()
        motion.delegate = self
        guard motion.isDeviceMotionAvailable else { setIcon("👁 ✗"); return }
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, err in
            guard let self = self, let dm = dm, err == nil else { return }
            self.onSample(dm)
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watchdog() }
    }

    func setIcon(_ t: String) { status.button?.title = t }

    func onSample(_ dm: CMDeviceMotion) {
        samples += 1
        lastSample = Date()
        if samples < 10 { return }                       // first samples are settling garbage
        let r = dm.rotationRate
        lastGyro = (r.x*r.x + r.y*r.y + r.z*r.z).squareRoot()
        lastYaw = dm.attitude.yaw
        let now = Date()
        // stillness tracker (needed for zeroing + drift compensation)
        if lastGyro < 0.1 { if stillSince == nil { stillSince = now } } else { stillSince = nil }
        if zero == nil {
            if let s = stillSince, now.timeIntervalSince(s) > 0.3 { zero = lastYaw; setIcon(enabled ? "👁" : "👁 ⏸") }
            return
        }
        let d = shortestArc(lastYaw - zero!)
        let deg = abs(d) * 180 / .pi
        // slow drift compensation: while facing screen & still, pull zero toward current yaw
        if deg < 10, stillSince != nil {
            let dt = now.timeIntervalSince(lastDriftTick)
            zero = zero! + d * min(1, dt / DRIFT_TAU_S)
        }
        lastDriftTick = now
        guard enabled else { return }
        if deg > BLUR_ON_DEG {
            belowOffSince = nil
            if pastOnSince == nil { pastOnSince = now }
            if now.timeIntervalSince(pastOnSince!) >= ON_DEBOUNCE { overlay.show(); setIcon("👁 ●") }
        } else if deg < BLUR_OFF_DEG {
            pastOnSince = nil
            if belowOffSince == nil { belowOffSince = now }
            if now.timeIntervalSince(belowOffSince!) >= OFF_DEBOUNCE { overlay.hide(); setIcon("👁") }
        } else { pastOnSince = nil; belowOffSince = nil }
    }

    func shortestArc(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

    func watchdog() {
        if Date().timeIntervalSince(lastSample) > WATCHDOG_S {
            if overlay.shown { overlay.hide() }
            if samples > 0 { setIcon("👁 ✗"); samples = 0; zero = nil; stillSince = nil }
        }
    }

    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) { samples = 0; zero = nil; setIcon("👁 …") }
    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) { overlay.hide(); zero = nil; samples = 0; setIcon("👁 ✗") }

    @objc func zeroNow() { zero = nil; stillSince = nil; pastOnSince = nil; overlay.hide(); setIcon("👁 …") }
    @objc func togglePause() { enabled.toggle(); if !enabled { overlay.hide() }; setIcon(enabled ? "👁" : "👁 ⏸") }
    @objc func quit() { overlay.hide(); motion.stopDeviceMotionUpdates(); NSApp.terminate(nil) }

    @objc func installLaunchAgent() {
        let exe = Bundle.main.bundlePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>com.siva.lookawayblur</string>
        <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>\(exe)</string></array>
        <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        let p = NSHomeDirectory() + "/Library/LaunchAgents/com.siva.lookawayblur.plist"
        try? plist.write(toFile: p, atomically: true, encoding: .utf8)
        setIcon("👁 ✓")
        DispatchQueue.main.asyncAfter(deadline: .now()+2) { self.setIcon(self.enabled ? "👁" : "👁 ⏸") }
    }

    // Global hotkeys via Carbon (no Accessibility permission needed). ⌃⌥Z = zero, ⌃⌥X = pause.
    func registerHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, evt, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(evt, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if hk.id == 1 { app.zeroNow() } else if hk.id == 2 { app.togglePause() }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_Z), mods, EventHotKeyID(signature: 0x4C41424C, id: 1), GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_ANSI_X), mods, EventHotKeyID(signature: 0x4C41424C, id: 2), GetApplicationEventTarget(), 0, &ref)
    }
}

let app = App()
let nsapp = NSApplication.shared
nsapp.setActivationPolicy(.accessory)
nsapp.delegate = app
nsapp.run()
