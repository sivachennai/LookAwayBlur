// LookAwayBlur — blurs all Mac screens when (a) your AirPods say your head is turned away,
// or (b) the camera sees a second face looking at your screen. Menu-bar app, no windows.
// Hotkeys: ⌃⌥Z = zero head position (facing screen), ⌃⌥X = pause/resume everything (panic clear).
import Cocoa
import CoreMotion
import AVFoundation
import Vision
import Carbon.HIToolbox

let BLUR_ON_DEG  = 40.0   // |delta yaw| above this → blur
let BLUR_OFF_DEG = 25.0   // |delta yaw| below this → clear (hysteresis)
let ON_DEBOUNCE  = 0.30   // seconds past threshold before blurring
let OFF_DEBOUNCE = 0.15
let WATCHDOG_S   = 1.5    // no motion sample for this long → clear + "no signal"
let DRIFT_TAU_S  = 90.0   // slow re-zero while facing screen and still
let PEEK_FPS     = 5.0    // camera frames analysed per second
let PEEK_ON_S    = 0.6    // second face present this long → blur
let PEEK_OFF_S   = 1.5    // second face gone this long → clear
let MIN_FACE_W   = 0.04   // ignore detections narrower than 4% of frame (noise)
let DEBUG = ProcessInfo.processInfo.environment["LAB_DEBUG"] != nil

enum Reason: String { case head = "You looked away", peek = "Someone else is looking" }

// MARK: - Overlay (one blur window per screen, shown while any reason is active)
final class Overlay {
    private var windows: [NSWindow] = []
    private var labels: [NSTextField] = []
    private(set) var reasons = Set<Reason>()
    var shown: Bool { !reasons.isEmpty }
    init() { build(); NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in self.build() } }
    func build() {
        windows.forEach { $0.orderOut(nil) }; windows = []; labels = []
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
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 22, weight: .medium); l.textColor = NSColor.white.withAlphaComponent(0.7)
            l.alignment = .center; l.frame = NSRect(x: 0, y: s.frame.height/2 - 20, width: s.frame.width, height: 40)
            l.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            v.addSubview(l); labels.append(l)
            w.contentView = v
            w.alphaValue = 0
            windows.append(w)
        }
        if shown { windows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() } }
    }
    func set(_ r: Reason, _ active: Bool) {
        let was = shown
        if active { reasons.insert(r) } else { reasons.remove(r) }
        let text = reasons.contains(.peek) ? Reason.peek.rawValue : (reasons.contains(.head) ? Reason.head.rawValue : "")
        labels.forEach { $0.stringValue = text }
        if shown && !was { show() } else if !shown && was { hide() }
    }
    func clearAll() { reasons.removeAll(); hide() }
    private func show() {
        windows.forEach { $0.alphaValue = 0; $0.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; self.windows.forEach { $0.animator().alphaValue = 1 } }
    }
    private func hide() {
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; self.windows.forEach { $0.animator().alphaValue = 0 } },
                                            completionHandler: { if !self.shown { self.windows.forEach { $0.orderOut(nil) } } })
    }
}

// MARK: - Head tracking (AirPods)
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    let motion = CMHeadphoneMotionManager()
    var onAway: ((Bool) -> Void)?          // true = turned away
    var onStatus: ((String) -> Void?)?     // "…" zeroing, "" ok, "✗" no signal
    private var zero: Double? = nil
    private var stillSince: Date? = nil, pastOnSince: Date? = nil, belowOffSince: Date? = nil
    private var lastSample = Date.distantPast, samples = 0, lastDriftTick = Date()
    var enabled = true { didSet { if !enabled { onAway?(false) } } }
    var available: Bool { motion.isDeviceMotionAvailable }

    func start() {
        motion.delegate = self
        guard available else { onStatus?("✗"); return }
        onStatus?("…")
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, err in
            guard let self = self, let dm = dm, err == nil else { return }
            self.onSample(dm)
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watchdog() }
    }
    func stop() { motion.stopDeviceMotionUpdates() }
    func rezero() { zero = nil; stillSince = nil; pastOnSince = nil; onAway?(false); onStatus?("…") }

    private func onSample(_ dm: CMDeviceMotion) {
        samples += 1; lastSample = Date()
        if samples < 10 { return }                       // first samples are settling garbage
        let r = dm.rotationRate
        let gyro = (r.x*r.x + r.y*r.y + r.z*r.z).squareRoot()
        let yaw = dm.attitude.yaw
        let now = Date()
        if gyro < 0.1 { if stillSince == nil { stillSince = now } } else { stillSince = nil }
        if zero == nil {
            if let s = stillSince, now.timeIntervalSince(s) > 0.3 { zero = yaw; onStatus?("") }
            return
        }
        let d = atan2(sin(yaw - zero!), cos(yaw - zero!))   // shortest arc, handles ±180 wrap
        let deg = abs(d) * 180 / .pi
        if deg < 10, stillSince != nil {                    // slow drift compensation while facing screen
            zero = zero! + d * min(1, now.timeIntervalSince(lastDriftTick) / DRIFT_TAU_S)
        }
        lastDriftTick = now
        guard enabled else { return }
        if deg > BLUR_ON_DEG {
            belowOffSince = nil
            if pastOnSince == nil { pastOnSince = now }
            if now.timeIntervalSince(pastOnSince!) >= ON_DEBOUNCE { onAway?(true) }
        } else if deg < BLUR_OFF_DEG {
            pastOnSince = nil
            if belowOffSince == nil { belowOffSince = now }
            if now.timeIntervalSince(belowOffSince!) >= OFF_DEBOUNCE { onAway?(false) }
        } else { pastOnSince = nil; belowOffSince = nil }
    }
    private func watchdog() {
        if Date().timeIntervalSince(lastSample) > WATCHDOG_S, samples > 0 {
            onAway?(false); onStatus?("✗"); samples = 0; zero = nil; stillSince = nil
        }
    }
    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) { samples = 0; zero = nil; onStatus?("…") }
    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) { onAway?(false); zero = nil; samples = 0; onStatus?("✗") }
}

// MARK: - Shoulder-surf guard (camera + Vision face count; frames never leave the device)
final class PeekGuard: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPeek: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?      // "" ok, "✗" no camera / denied
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lab.peek")
    private var lastFrame = Date.distantPast
    private var secondFaceSince: Date? = nil, noSecondSince: Date? = nil
    private var peeking = false
    private(set) var running = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { ok ? self.configure() : self.onStatus?("✗") }
        }
    }
    private func configure() {
        guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { onStatus?("✗"); return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
        running = true; onStatus?("")
    }
    func stop() {
        guard running else { return }
        running = false
        queue.async { self.session.stopRunning() }
        setPeek(false); secondFaceSince = nil; noSecondSince = nil
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= 1.0 / PEEK_FPS, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastFrame = now
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .up, options: [:]).perform([req])
        let raw = req.results ?? []
        let faces = raw.filter { $0.boundingBox.width >= MIN_FACE_W }
        if DEBUG { FileHandle.standardError.write("faces=\(faces.count)/raw=\(raw.count) \(raw.map { String(format: "%.2f", $0.boundingBox.width) })\n".data(using: .utf8)!) }
        // The largest face is the owner; any additional face is a peeker.
        let second = faces.count >= 2
        if second {
            noSecondSince = nil
            if secondFaceSince == nil { secondFaceSince = now }
            if now.timeIntervalSince(secondFaceSince!) >= PEEK_ON_S { setPeek(true) }
        } else {
            secondFaceSince = nil
            if noSecondSince == nil { noSecondSince = now }
            if now.timeIntervalSince(noSecondSince!) >= PEEK_OFF_S { setPeek(false) }
        }
    }
    private func setPeek(_ p: Bool) {
        guard p != peeking else { return }
        peeking = p
        DispatchQueue.main.async { self.onPeek?(p) }
    }
}

// MARK: - App
final class App: NSObject, NSApplicationDelegate {
    let overlay = Overlay()
    let head = HeadTracker()
    let peek = PeekGuard()
    var status: NSStatusItem!
    var headItem: NSMenuItem!, peekItem: NSMenuItem!
    var paused = false
    var headStatus = "", peekStatus = ""
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        headItem = menu.addItem(withTitle: "Look-away blur (AirPods)", action: #selector(toggleHead), keyEquivalent: "")
        peekItem = menu.addItem(withTitle: "Shoulder-surf guard (camera)", action: #selector(togglePeek), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Zero — I'm facing the screen  (⌃⌥Z)", action: #selector(zeroNow), keyEquivalent: "")
        menu.addItem(withTitle: "Pause / Resume all  (⌃⌥X)", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Install Launch at Login", action: #selector(installLaunchAgent), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        status.menu = menu
        registerHotkeys()

        head.onAway = { [weak self] away in self?.overlay.set(.head, away); self?.refreshIcon() }
        head.onStatus = { [weak self] s in self?.headStatus = s; self?.refreshIcon() }
        peek.onPeek = { [weak self] p in self?.overlay.set(.peek, p); self?.refreshIcon() }
        peek.onStatus = { [weak self] s in self?.peekStatus = s; self?.refreshIcon() }

        let headOn = defaults.object(forKey: "headEnabled") as? Bool ?? true
        let peekOn = defaults.object(forKey: "peekEnabled") as? Bool ?? true
        head.enabled = headOn; head.start()
        if peekOn { peek.start() }
        headItem.state = headOn ? .on : .off
        peekItem.state = peekOn ? .on : .off
        refreshIcon()
    }

    func refreshIcon() {
        var t = "👁"
        if paused { t += " ⏸" }
        else if overlay.shown { t += overlay.reasons.contains(.peek) ? " 👀" : " ●" }
        else if headItem.state == .on && headStatus == "…" { t += " …" }
        else if (headItem.state == .on && headStatus == "✗") || (peekItem.state == .on && peekStatus == "✗") { t += " ✗" }
        status.button?.title = t
    }

    @objc func toggleHead() {
        headItem.state = headItem.state == .on ? .off : .on
        head.enabled = headItem.state == .on
        defaults.set(head.enabled, forKey: "headEnabled"); refreshIcon()
    }
    @objc func togglePeek() {
        peekItem.state = peekItem.state == .on ? .off : .on
        if peekItem.state == .on { peek.start() } else { peek.stop() }
        defaults.set(peekItem.state == .on, forKey: "peekEnabled"); refreshIcon()
    }
    @objc func zeroNow() { head.rezero() }
    @objc func togglePause() {
        paused.toggle()
        if paused { overlay.clearAll(); head.enabled = false; peek.stop() }
        else { head.enabled = headItem.state == .on; if peekItem.state == .on { peek.start() } }
        refreshIcon()
    }
    @objc func quit() { overlay.clearAll(); head.stop(); peek.stop(); NSApp.terminate(nil) }

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
        status.button?.title = "👁 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now()+2) { self.refreshIcon() }
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
