import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

// Private but long-stable: maps an AX window to its CGWindowID (used by AltTab, yabai).
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: inout CGWindowID) -> AXError

struct Win {
    let ax: AXUIElement
    let id: CGWindowID
    let app: NSRunningApplication
    let title: String
    let minimized: Bool
    let z: Int
}

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func optionDown() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
}

// MARK: - Window enumeration

func listWindows() -> [Win] {
    // Front-to-back z-order of on-screen windows. Needs no permission (we only read ids).
    var z = [CGWindowID: Int]()
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for (i, w) in list.enumerated() where w[kCGWindowLayer as String] as? Int == 0 {
            if let id = w[kCGWindowNumber as String] as? CGWindowID { z[id] = i }
        }
    }
    let me = getpid()
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
    var perApp = [[Win]](repeating: [], count: apps.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: apps.count) { i in
        let app = apps[i]
        guard let ws: [AXUIElement] = attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) else { return }
        var out = [Win]()
        for (j, w) in ws.enumerated() {
            guard attr(w, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole else { continue }
            var id: CGWindowID = 0
            _AXUIElementGetWindow(w, &id)
            let title = attr(w, kAXTitleAttribute) as String? ?? ""
            out.append(Win(ax: w, id: id, app: app,
                           title: title.isEmpty ? app.localizedName ?? "" : title,
                           minimized: attr(w, kAXMinimizedAttribute) as Bool? ?? false,
                           // Off-screen (minimized/hidden) windows go last, grouped by app.
                           z: z[id] ?? 1_000_000 + i * 1000 + j))
        }
        lock.lock(); perApp[i] = out; lock.unlock()
    }
    return perApp.joined().sorted { $0.z < $1.z }
}

func focus(_ w: Win) {
    if w.app.isHidden { w.app.unhide() }
    if w.minimized { AXUIElementSetAttributeValue(w.ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w.ax, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w.ax, kAXMainAttribute as CFString, kCFBooleanTrue)
}

// Window previews need Screen Recording; without it tiles show app icons only.
func capture(_ ids: Set<CGWindowID>, _ done: @escaping (CGWindowID, NSImage) -> Void) {
    guard !ids.isEmpty, CGPreflightScreenCaptureAccess() else { return }
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
        for w in content?.windows ?? [] where ids.contains(w.windowID) && w.frame.width > 0 && w.frame.height > 0 {
            // Pixel size for the largest preview at 2x.
            let k = min(2 * Grid.pw / w.frame.width, 2 * Grid.ph / w.frame.height, 2)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * k)
            cfg.height = Int(w.frame.height * k)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) { img, _ in
                guard let img else { return }
                let ns = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2))
                DispatchQueue.main.async { done(w.windowID, ns) }
            }
        }
    }
}

func aspectFit(_ size: NSSize, in r: NSRect) -> NSRect {
    let k = min(r.width / size.width, r.height / size.height)
    return NSRect(x: r.midX - size.width * k / 2, y: r.midY - size.height * k / 2, width: size.width * k, height: size.height * k)
}

// MARK: - UI

final class Grid: NSView {
    // Preview size at scale 1; tiles shrink until the grid fits the screen.
    static let pw: CGFloat = 220, ph: CGFloat = 140, pad: CGFloat = 12, maxCols = 6
    var wins: [Win] = [], sel = 0, cols = 1, scale: CGFloat = 1
    var previews: [CGWindowID: NSImage] = [:]  // kept across shows so the panel never opens blank
    var tw: CGFloat { Grid.pw * scale + 16 }
    var th: CGFloat { Grid.ph * scale + 38 }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        guard p.x >= Grid.pad, p.y >= Grid.pad else { return nil }
        let c = Int((p.x - Grid.pad) / tw), i = Int((p.y - Grid.pad) / th) * cols + c
        return c < cols && i < wins.count ? i : nil
    }

    // Close and quit buttons at the right end of the selected tile's title row, below the preview.
    func buttons(_ i: Int) -> (close: NSRect, quit: NSRect) {
        let f = tileRect(i), s: CGFloat = 18, y = f.minY + Grid.ph * scale + 13
        return (NSRect(x: f.maxX - 12 - 2 * s, y: y, width: s, height: s), NSRect(x: f.maxX - 8 - s, y: y, width: s, height: s))
    }

    static func symbol(_ name: String, _ label: String, _ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white, color])))
    }
    static let closeIcon = symbol("xmark.circle.fill", "Close window", .systemRed)
    static let quitIcon = symbol("power.circle.fill", "Quit app", .systemOrange)

    // Hover selects, click switches (or closes/quits via the buttons), click between tiles cancels.
    override func mouseMoved(with e: NSEvent) { if let i = index(e), i != sel { switcher.select(i) } }
    override func mouseDown(with e: NSEvent) {
        guard let i = index(e) else { switcher.stop(); return }
        // Buttons are only drawn on the selected tile, so only it can hit them.
        let p = convert(e.locationInWindow, from: nil), b = buttons(i)
        if i == sel && b.close.contains(p) { switcher.close(i) } else if i == sel && b.quit.contains(p) { switcher.quit(i) } else { switcher.select(i); switcher.finish() }
    }

    static let attrs: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white, .paragraphStyle: p]
    }()

    func layout(_ n: Int, _ maxW: CGFloat, _ maxH: CGFloat) -> NSSize {
        scale = 1
        while true {
            cols = max(1, min(n, Grid.maxCols, Int((maxW - Grid.pad * 2) / tw)))
            let h = CGFloat((n + cols - 1) / cols) * th + Grid.pad * 2
            if h <= maxH || scale < 0.2 { return NSSize(width: CGFloat(cols) * tw + Grid.pad * 2, height: h) }
            scale *= 0.9
        }
    }

    func tileRect(_ i: Int) -> NSRect {
        NSRect(x: Grid.pad + CGFloat(i % cols) * tw, y: Grid.pad + CGFloat(i / cols) * th, width: tw, height: th)
    }

    override func draw(_ dirty: NSRect) {
        for (i, w) in wins.enumerated() {
            let f = tileRect(i)
            guard f.intersects(dirty) else { continue }
            if i == sel {
                NSColor.white.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: f.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            let alpha: CGFloat = w.minimized ? 0.5 : 1
            let area = NSRect(x: f.minX + 8, y: f.minY + 8, width: f.width - 16, height: Grid.ph * scale)
            let icon = w.app.icon ?? NSImage()
            if let img = previews[w.id] {
                img.draw(in: aspectFit(img.size, in: area), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            } else {
                let s = min(area.width, area.height) * 0.6
                icon.draw(in: NSRect(x: area.midX - s / 2, y: area.midY - s / 2, width: s, height: s), from: .zero,
                          operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            }
            let ty = area.maxY + 6
            icon.draw(in: NSRect(x: f.minX + 8, y: ty, width: 16, height: 16), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            // The selected tile's title makes room for the buttons.
            let titleW = f.width - (i == sel ? 80 : 36)
            (w.title as NSString).draw(in: NSRect(x: f.minX + 28, y: ty + 1, width: titleW, height: 16), withAttributes: Grid.attrs)
            if i == sel {
                let b = buttons(i)
                Grid.closeIcon?.draw(in: b.close, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                Grid.quitIcon?.draw(in: b.quit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

// MARK: - Switcher

final class Switcher {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    let grid = Grid()
    var active = false
    var timer: Timer?
    var showWork: DispatchWorkItem?
    var tempKeys: [EventHotKeyRef] = []

    init() {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .vibrantDark)
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        panel.contentView = fx
        grid.autoresizingMask = [.width, .height]
        fx.addSubview(grid)
    }

    func hotkey(_ id: UInt32) {
        switch id {
        case 1, 2:
            let d = id == 1 ? 1 : -1
            active ? move(d) : start(d)
        case 3: stop()
        case 4: move(-1)
        case 5: move(1)
        case 6: moveRow(-1)
        case 7: moveRow(1)
        default: break
        }
    }

    func start(_ d: Int) {
        guard AXIsProcessTrusted() else { promptAccessibility(); return }
        let wins = listWindows()
        guard !wins.isEmpty else { return }
        active = true
        grid.wins = wins
        // Skip the current window only if it is in the list (the frontmost app may have no standard window).
        let skip = wins.count > 1 && wins[0].app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier ? 1 : 0
        grid.sel = d > 0 ? skip : wins.count - 1
        tempKeys = [register(kVK_Escape, optionKey, 3), register(kVK_LeftArrow, optionKey, 4), register(kVK_RightArrow, optionKey, 5),
                    register(kVK_UpArrow, optionKey, 6), register(kVK_DownArrow, optionKey, 7)].compactMap { $0 }
        let t = Timer(timeInterval: 0.01, repeats: true) { [unowned self] _ in if !optionDown() { self.finish() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        makeClickTap()
        swallowUp = false
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
        // Quick taps switch without ever showing the panel.
        let w = DispatchWorkItem { [unowned self] in self.show() }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func show() {
        let wins = grid.wins
        let ids = Set(wins.map(\.id))
        grid.previews = grid.previews.filter { ids.contains($0.key) }
        relayout()
        panel.orderFrontRegardless()
        // Minimized and hidden windows can't be captured; they keep their last preview.
        capture(Set(wins.filter { !$0.minimized && !$0.app.isHidden }.map(\.id))) { [unowned self] id, img in
            self.grid.previews[id] = img
            if self.active, let i = self.grid.wins.firstIndex(where: { $0.id == id }) { self.grid.setNeedsDisplay(self.grid.tileRect(i)) }
        }
    }

    func relayout() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let size = grid.layout(grid.wins.count, vf.width * 0.9, vf.height * 0.9)
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: false)
        grid.needsDisplay = true
    }

    // Unsaved changes may make the window or app refuse; it reappears next time.
    func close(_ i: Int) {
        let w = grid.wins[i]
        if let b: AXUIElement = attr(w.ax, kAXCloseButtonAttribute) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
        remove { $0.id == w.id }
    }

    func quit(_ i: Int) {
        let app = grid.wins[i].app
        app.terminate()
        remove { $0.app == app }
    }

    // Selection follows its window, or the next one if it was removed.
    func remove(_ gone: (Win) -> Bool) {
        let kept = grid.wins.prefix(grid.sel).filter { !gone($0) }.count
        grid.wins.removeAll(where: gone)
        guard !grid.wins.isEmpty else { stop(); return }
        grid.sel = min(kept, grid.wins.count - 1)
        relayout()
    }

    // Hotkey and mouse events can arrive after stop() has emptied the list.
    func move(_ d: Int) {
        guard active else { return }
        let n = grid.wins.count
        select((grid.sel + d + n) % n)
    }

    // Up/down by one row, wrapping to the other end of the same column.
    func moveRow(_ d: Int) {
        let n = grid.wins.count, c = grid.cols, col = grid.sel % c, s = grid.sel + d * c
        select(s >= n ? col : s < 0 ? col + (n - 1 - col) / c * c : s)
    }

    func select(_ i: Int) {
        guard active else { return }
        grid.setNeedsDisplay(grid.tileRect(grid.sel))
        grid.sel = i
        grid.setNeedsDisplay(grid.tileRect(i))
    }

    func finish() {
        guard active else { return }
        let w = grid.wins[grid.sel]
        stop()
        focus(w)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        showWork?.cancel(); showWork = nil
        panel.orderOut(nil)
        // Keep the tap until the swallowed click's mouse-up has been eaten too.
        if let clickTap, !swallowUp { CGEvent.tapEnable(tap: clickTap, enable: false) }
        tempKeys.forEach { UnregisterEventHotKey($0) }
        tempKeys = []
        grid.wins = []
        active = false
    }
}

// MARK: - Hotkeys and startup

func register(_ key: Int, _ mods: Int, _ id: UInt32) -> EventHotKeyRef? {
    var ref: EventHotKeyRef?
    let st = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: 0x414C_5442, id: id), GetApplicationEventTarget(), 0, &ref)
    if st != noErr { NSLog("RegisterEventHotKey(%d) failed: %d", id, st) }
    return ref
}

func promptAccessibility() {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
}

let app = NSApplication.shared
let switcher = Switcher()

// A click outside the open switcher cancels it and is swallowed: with Option held it would otherwise
// reach the clicked app as an Option-click, which hides apps. Enabled only while the switcher is open.
var swallowUp = false
var clickTap: CFMachPort?

// Creating the tap needs Accessibility, so start() retries until it has been granted.
func makeClickTap() {
    guard clickTap == nil else { return }
    clickTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].reduce(0) { $0 | 1 << $1.rawValue },
        callback: { _, type, event, _ in
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if switcher.active, let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
            case .leftMouseDown, .rightMouseDown:
                let p = switcher.panel
                if switcher.active && !(p.isVisible && NSMouseInRect(NSEvent.mouseLocation, p.frame, false)) {
                    swallowUp = true
                    switcher.stop()
                    return nil
                }
            case .leftMouseUp, .rightMouseUp:
                if swallowUp {
                    swallowUp = false
                    if !switcher.active, let clickTap { CGEvent.tapEnable(tap: clickTap, enable: false) }
                    return nil
                }
            default: break
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    if let clickTap {
        CGEvent.tapEnable(tap: clickTap, enable: false)
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, clickTap, 0), .commonModes)
    }
}
makeClickTap()

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var hk = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hk)
    switcher.hotkey(hk.id)
    return noErr
}, 1, &spec, nil, nil)
_ = register(kVK_Tab, optionKey, 1)
_ = register(kVK_Tab, optionKey | shiftKey, 2)

// A hung app must not stall the switcher.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
if !AXIsProcessTrusted() { promptAccessibility() }
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

app.run()
