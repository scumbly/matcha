// Matcha — a modern, supported re-implementation of the classic "Caffeine" menulet.
//
//  • Left-click the menu-bar cup to toggle keep-awake on/off, using your selected duration.
//  • Right-click (or control-click) for a menu to choose that duration and options.
//  • Optional global hotkey (⌃⌘M) and "disable on low battery" (laptop or UPS).
//
// Mechanism: an IOKit power assertion of type PreventUserIdleDisplaySleep — the same
// thing `caffeinate -d` does, but held in-process so there is no child process to manage.
// Timed activations auto-release via a Timer. Launch-at-login uses SMAppService (macOS 13+).
//
// Copyright © 2026 Jesse Holden.
// SPDX-License-Identifier: GPL-3.0-or-later
// Matcha is free software under the GNU GPL v3 or later; see LICENSE.

import Cocoa
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Duration presets. 0 == indefinite. Title doubles as the persisted key + checkmark key.
    private let durations: [(title: String, seconds: TimeInterval)] = [
        ("Indefinitely", 0),
        ("15 minutes", 15 * 60),
        ("1 hour",      60 * 60),
        ("4 hours",  4 * 60 * 60),
        ("8 hours",  8 * 60 * 60),
    ]

    private let durationKey   = "MatchaSelectedDuration"
    private let hotKeyKey     = "MatchaHotKeyEnabled"
    private let lowBatteryKey = "MatchaLowBatteryEnabled"
    private let lowBatteryThreshold = 10   // percent

    private var statusItem: NSStatusItem!
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var expiryDate: Date?

    // User intent vs. what's actually held. The assertion is held only when the user
    // wants it AND low-battery suppression isn't active.
    private var wantActive = false
    private var lowBatterySuppressed = false
    private var effectiveActive: Bool { wantActive && !lowBatterySuppressed }

    // The user's chosen duration — drives left-click and persists across launches.
    private var selectedLabel = "Indefinitely"

    // Persisted option toggles.
    private var hotKeyEnabled = false
    private var lowBatteryEnabled = false
    private var deviceHasBattery = false

    // Re-renders the menu-bar glyph when the menu bar switches light/dark.
    private var appearanceObservation: NSKeyValueObservation?

    // Carbon global hotkey + IOKit power-source monitor.
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var powerSource: CFRunLoopSource?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the bundled icon for the About panel (and any other system UI).
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }

        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: durationKey),
           durations.contains(where: { $0.title == saved }) {
            selectedLabel = saved
        }
        hotKeyEnabled = defaults.bool(forKey: hotKeyKey)
        lowBatteryEnabled = defaults.bool(forKey: lowBatteryKey)
        deviceHasBattery = detectBattery()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                self?.updateIcon()
            }
        }

        if deviceHasBattery {
            startBatteryMonitor()
            evaluateLowBattery()
        }
        if hotKeyEnabled { registerHotKey() }

        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appearanceObservation?.invalidate()
        unregisterHotKey()
        releaseAssertionAndTimer()
    }

    // MARK: - Click routing

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            showMenu()
        } else {
            toggle()
        }
    }

    private func toggle() { setWantActive(!wantActive) }

    private func seconds(for label: String) -> TimeInterval {
        durations.first(where: { $0.title == label })?.seconds ?? 0
    }

    // MARK: - Activation

    /// Sets the user's intent and (re)arms the auto-off timer. Whether the assertion
    /// is actually held is decided by applyAssertionState() (see low-battery suppression).
    private func setWantActive(_ on: Bool) {
        wantActive = on
        timer?.invalidate(); timer = nil
        expiryDate = nil
        if on {
            let secs = seconds(for: selectedLabel)
            if secs > 0 {
                expiryDate = Date().addingTimeInterval(secs)
                timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                    self?.setWantActive(false)
                }
            }
        }
        applyAssertionState()
    }

    /// Acquires or releases the IOKit assertion to match `effectiveActive`, then
    /// refreshes the icon. Does not touch the timer, so a suppressed timed session
    /// keeps counting down and resumes cleanly when power returns.
    private func applyAssertionState() {
        if effectiveActive {
            if assertionID == 0 {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Matcha is keeping the display on" as CFString,
                    &id)
                if result == kIOReturnSuccess {
                    assertionID = id
                } else {
                    NSLog("Matcha: failed to create power assertion (code \(result))")
                }
            }
        } else if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        updateIcon()
    }

    private func releaseAssertionAndTimer() {
        timer?.invalidate(); timer = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    // MARK: - Battery (internal batteries and UPS units)

    /// Descriptions of every power source we care about: an internal (laptop)
    /// battery or an attached UPS. A desktop on a UPS qualifies just like a laptop.
    private func relevantSources() -> [[String: Any]] {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        var result: [[String: Any]] = []
        for s in sources {
            guard let d = IOPSGetPowerSourceDescription(snap, s)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let type = d[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType || type == kIOPSUPSType {
                result.append(d)
            }
        }
        return result
    }

    private func detectBattery() -> Bool {
        !relevantSources().isEmpty
    }

    /// True if any relevant source is currently discharging (on battery / UPS during
    /// an outage) and at or below the threshold — i.e. keep-awake should back off.
    private func shouldSuppressForLowBattery() -> Bool {
        for d in relevantSources() {
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let mx  = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : 100
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            if onBattery && pct <= lowBatteryThreshold { return true }
        }
        return false
    }

    private func startBatteryMonitor() {
        guard powerSource == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ userData in
            guard let userData else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.evaluateLowBattery() }
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    /// Recomputes low-battery suppression and applies it if it changed.
    private func evaluateLowBattery() {
        let suppress = lowBatteryEnabled && shouldSuppressForLowBattery()
        if suppress != lowBatterySuppressed {
            lowBatterySuppressed = suppress
            applyAssertionState()
        }
    }

    // MARK: - Global hotkey (⌃⌘M)

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { (_, _, userData) -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
    }

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        installHotKeyHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4D544348), id: 1)   // 'MTCH'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | controlKey), id,
                            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Icon & status text

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = cupImage(active: effectiveActive, appearance: button.effectiveAppearance)
        if effectiveActive {
            button.toolTip = statusLine()
        } else if wantActive && lowBatterySuppressed {
            button.toolTip = "Matcha — paused (battery low); resumes on power"
        } else {
            button.toolTip = "Matcha — inactive (left-click for \(selectedLabel.lowercased()))"
        }
    }

    /// Menu-bar glyph: an empty outlined coffee cup when inactive; when active,
    /// the cup fills solid in `labelColor` with a disc of green matcha at the
    /// opening. The outline/fill use `labelColor` resolved against the menu bar's
    /// appearance (so it adapts to light/dark); only the matcha is a fixed green,
    /// which is why this image is non-template.
    private func cupImage(active: Bool, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            appearance.performAsCurrentDrawingAppearance {
                AppDelegate.drawCup(in: ctx, width: size.width, active: active)
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = active ? "Matcha: active" : "Matcha: inactive"
        return image
    }

    private static func drawCup(in ctx: CGContext, width: CGFloat, active: Bool) {
        let matcha = NSColor(srgbRed: 0.45, green: 0.72, blue: 0.18, alpha: 1)
        let cupCx = width / 2 - 1.7       // shift left to leave room for the handle
        let rimY: CGFloat = 12.0, rimRX: CGFloat = 6.2, rimRY: CGFloat = 1.9
        let botY: CGFloat = 2.8

        // Open bowl outline: two symmetric curves to a rounded bottom centre with
        // a slight belly — an espresso-cup shape. Horizontal tangent at the base.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: cupCx - rimRX, y: rimY))
        body.addCurve(to: CGPoint(x: cupCx, y: botY),
                      control1: CGPoint(x: cupCx - rimRX - 0.4, y: rimY - 6.5),
                      control2: CGPoint(x: cupCx - 4.3, y: botY))
        body.addCurve(to: CGPoint(x: cupCx + rimRX, y: rimY),
                      control1: CGPoint(x: cupCx + 4.3, y: botY),
                      control2: CGPoint(x: cupCx + rimRX + 0.4, y: rimY - 6.5))

        // Handle: a "D" loop off the right wall. Endpoints sit on the wall so they
        // merge with the body outline instead of poking inside.
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: cupCx + rimRX - 0.1, y: 9.8))
        handle.addCurve(to: CGPoint(x: cupCx + rimRX + 0.2, y: 5.6),
                        control1: CGPoint(x: cupCx + rimRX + 3.7, y: 9.4),
                        control2: CGPoint(x: cupCx + rimRX + 3.7, y: 6.0))

        let rimRect = CGRect(x: cupCx - rimRX, y: rimY - rimRY, width: rimRX * 2, height: rimRY * 2)

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if active {
            // Solid cup silhouette in the outline colour.
            NSColor.labelColor.setFill()
            let filled = body.mutableCopy()!
            filled.closeSubpath()                 // straight top, hidden under the rim ellipse
            ctx.addPath(filled); ctx.fillPath()
            ctx.fillEllipse(in: rimRect)          // rounds the opening
            // Handle as a thick stroke so its hole reads.
            NSColor.labelColor.setStroke(); ctx.setLineWidth(1.7)
            ctx.addPath(handle); ctx.strokePath()
            // Green matcha at the opening, framed by a thin ring of the cup colour.
            matcha.setFill()
            ctx.fillEllipse(in: rimRect.insetBy(dx: 1.5, dy: 0.5))
        } else {
            NSColor.labelColor.setStroke()
            ctx.setLineWidth(1.3)
            ctx.addPath(body); ctx.strokePath()
            ctx.addPath(handle); ctx.strokePath()
            ctx.addEllipse(in: rimRect); ctx.strokePath()
        }
    }

    private func statusLine() -> String {
        guard effectiveActive else { return "Inactive" }
        guard let expiry = expiryDate else { return "Active — indefinitely" }
        let remaining = max(0, Int(expiry.timeIntervalSinceNow))
        if remaining >= 3600 {
            return "Active — \(remaining / 3600)h \((remaining % 3600) / 60)m remaining"
        }
        return "Active — \(remaining / 60)m \(remaining % 60)s remaining"
    }

    // MARK: - Menu (right-click)

    private func showMenu() {
        let menu = NSMenu()

        let durationHeader = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
        durationHeader.isEnabled = false
        menu.addItem(durationHeader)
        for d in durations {
            let item = NSMenuItem(title: d.title, action: #selector(selectDuration(_:)), keyEquivalent: "")
            item.target = self
            if d.title == selectedLabel { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let hotkey = NSMenuItem(title: "Use ⌃⌘M", action: #selector(toggleHotKey), keyEquivalent: "")
        hotkey.target = self
        hotkey.state = hotKeyEnabled ? .on : .off
        menu.addItem(hotkey)

        if deviceHasBattery {
            let lowBatt = NSMenuItem(title: "Disable on low battery", action: #selector(toggleLowBattery), keyEquivalent: "")
            lowBatt.target = self
            lowBatt.state = lowBatteryEnabled ? .on : .off
            menu.addItem(lowBatt)
        }
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Matcha", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Matcha", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach the menu only for the duration of this click, then detach so the next
        // left-click fires our toggle action instead of re-opening the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        selectedLabel = sender.title
        UserDefaults.standard.set(selectedLabel, forKey: durationKey)
        // If we're already running, re-arm immediately with the new duration so the
        // change takes effect now. If inactive, just remember it for the next toggle.
        if wantActive {
            setWantActive(true)
        } else {
            updateIcon()
        }
    }

    @objc private func toggleHotKey() {
        hotKeyEnabled.toggle()
        UserDefaults.standard.set(hotKeyEnabled, forKey: hotKeyKey)
        if hotKeyEnabled { registerHotKey() } else { unregisterHotKey() }
    }

    @objc private func toggleLowBattery() {
        lowBatteryEnabled.toggle()
        UserDefaults.standard.set(lowBatteryEnabled, forKey: lowBatteryKey)
        evaluateLowBattery()   // apply immediately: may suppress now, or lift suppression
    }

    @objc private func showAbout() {
        // .accessory apps aren't frontmost, so bring the panel forward explicitly.
        NSApp.activate(ignoringOtherApps: true)

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let credits = NSAttributedString(
            string: "Keeps your Mac awake on demand.\n"
                  + "Left-click the cup to toggle; right-click to pick a duration.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])

        // Name, version, icon, and copyright are read from Info.plist automatically.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Matcha: launch-at-login toggle failed: \(error)")
        }
    }

    @objc private func quit() {
        releaseAssertionAndTimer()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar agent: no Dock icon, no app menu
app.run()
