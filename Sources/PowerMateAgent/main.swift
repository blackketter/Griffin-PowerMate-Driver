#!/usr/bin/env swift
//
//  PowerMateAgent — runs in the background and turns PowerMate input into
//  keyboard/scroll events that any application can receive.
//
//  Rotation   → scroll, or arrow keys when a menu/submenu is focused
//  Click      → left mouse (at cursor), or Return when a menu is focused
//  Long press → right mouse button (then arrow keys until timeout or click)
//
//  Menu and submenu detection uses the Accessibility API so rotation and click
//  work in submenus without leaving “menu mode”. Enable Accessibility for that.
//  Requires Input Monitoring (System Settings → Privacy & Security).
//

import Foundation
import AppKit
import CoreGraphics
import CoreAudio
import ApplicationServices
import PowerMateDriver

let driver = PowerMateDriver()

// Scroll: lines per knob step (sensitivity); user can reverse direction via menu
let scrollLinesPerStep: Int32 = 2
var scrollReversed = false
var volumeAccumulator: Float = 0  // encoder steps toward next volume key press

enum RotationMode { case scroll, volume }
var rotationMode: RotationMode = .scroll

enum ButtonAction { case mouseClick, rightClick, doubleClick, mute, playPause }
var clickAction: ButtonAction = .mouseClick
var longPressAction: ButtonAction = .rightClick

// NX key type: PLAY=16 (play/pause via synthetic event)
func postMediaKey(_ keyType: Int32, down: Bool) {
    let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
    let data1 = Int((keyType << 16) | (down ? 0xa400 : 0xe400))
    guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
           modifierFlags: flags, timestamp: 0, windowNumber: 0,
           context: nil, subtype: 8, data1: data1, data2: -1),
          let cg = e.cgEvent else {
        NSLog("postMediaKey: failed to create event for keyType=%d down=%d", keyType, down ? 1 : 0)
        return
    }
    cg.post(tap: .cgSessionEventTap)
}

func postPlayPause() {
    postMediaKey(16, down: true)
    postMediaKey(16, down: false)
}

/// Post an NX consumer-control volume/mute event. These are system-defined events,
/// not keyboard events — the correct mechanism for volume keys on macOS.
func postNXVolumeKey(_ nxKeyType: Int32, down: Bool, fine: Bool = false) {
    let data1 = Int((nxKeyType << 16) | (down ? 0x0a00 : 0x0b00))
    let mods: NSEvent.ModifierFlags = fine ? [.option, .shift] : [.shift]
    guard let e = NSEvent.otherEvent(
        with: .systemDefined, location: .zero,
        modifierFlags: mods,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, subtype: 8,
        data1: data1, data2: -1),
        let cg = e.cgEvent else { return }
    cg.flags = fine ? [.maskAlternate, .maskShift] : [.maskShift]
    cg.post(tap: .cghidEventTap)
}

// Option+Shift gives fine steps (1/4 of a normal step) but re-enables the feedback sound.
// Shift-only suppresses sound but uses full steps. No standard API offers both.
// To silence feedback system-wide: System Settings → Sound → uncheck "Play feedback when volume is changed".
func postVolumeUp()   { postNXVolumeKey(kNXVolumeUp,   down: true,  fine: true); postNXVolumeKey(kNXVolumeUp,   down: false, fine: true) }
func postVolumeDown() { postNXVolumeKey(kNXVolumeDown, down: true,  fine: true); postNXVolumeKey(kNXVolumeDown, down: false, fine: true) }
func toggleSystemMute() { postNXVolumeKey(kNXMute, down: true); postNXVolumeKey(kNXMute, down: false) }

func postScroll(delta: Int) {
    var lines = Int32(delta) * scrollLinesPerStep
    if scrollReversed { lines = -lines }
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: lines,
        wheel2: 0,
        wheel3: 0
    ) else { return }
    event.post(tap: .cghidEventTap)
}

// Key codes (HIToolbox): Up = 0x7E, Down = 0x7D, Return = 0x24
private let kUpArrow: CGKeyCode = 0x7E
private let kDownArrow: CGKeyCode = 0x7D
private let kReturnKey: CGKeyCode = 0x24
// NX consumer-control key types (not CGKeyCodes — volume is not a keyboard event)
private let kNXVolumeUp: Int32 = 0
private let kNXVolumeDown: Int32 = 1
private let kNXMute: Int32 = 7

/// Post one key press (down + up).
func postKey(_ keyCode: CGKeyCode) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

/// Convert Cocoa screen point (bottom-left origin) to Quartz (top-left origin).
func cocoaToQuartz(_ cocoa: NSPoint) -> CGPoint {
    let screen = NSScreen.screens.first { NSMouseInRect(cocoa, $0.frame, false) } ?? NSScreen.main
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    return CGPoint(x: cocoa.x, y: frame.maxY - cocoa.y)
}

/// Post a mouse click at the given Quartz location.
func postMouseClick(at location: CGPoint, button: CGMouseButton = .left) {
    let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    if let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
       let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: location, mouseButton: button) {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Post a proper double-click at the given Quartz location using kCGMouseEventClickState = 2
/// so the system treats it as one double-click, not two single clicks.
func postDoubleClick(at location: CGPoint) {
    guard let down1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
          let up1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left),
          let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
          let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else { return }
    down1.post(tap: .cghidEventTap)
    up1.post(tap: .cghidEventTap)
    down2.setIntegerValueField(.mouseEventClickState, value: 2)
    up2.setIntegerValueField(.mouseEventClickState, value: 2)
    down2.post(tap: .cghidEventTap)
    up2.post(tap: .cghidEventTap)
}

/// Post a left or right mouse click at the current cursor position (like a trackpad tap or mouse click).
func postMouseClick(button: CGMouseButton = .left) {
    DispatchQueue.main.async {
        let cocoa = NSEvent.mouseLocation
        let location = cocoaToQuartz(cocoa)
        postMouseClick(at: location, button: button)
    }
}

func performButtonAction(_ action: ButtonAction) {
    switch action {
    case .mouseClick:  postMouseClick(button: .left)
    case .rightClick:  postMouseClick(button: .right)
    case .doubleClick:
        let cocoa = NSEvent.mouseLocation
        let location = cocoaToQuartz(cocoa)
        postDoubleClick(at: location)
    case .mute:        toggleSystemMute()
    case .playPause:   postPlayPause()
    }
}

// Menu behavior: use arrow keys + Return when a menu (or submenu) is focused.
// We use the Accessibility API so submenus are detected; long-press timeout is fallback.
var isMenuMode = false
var menuModeTimeout: DispatchWorkItem?
let menuModeTimeoutInterval: TimeInterval = 5.0

/// Returns true if the currently focused UI element is a menu or menu item (or inside one, e.g. submenu).
/// Requires Accessibility permission. Runs on main thread.
func isMenuFocused() -> Bool {
    guard Thread.isMainThread else { return false }
    let systemWide = AXUIElementCreateSystemWide()
    var appRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
          let app = appRef, CFGetTypeID(app) == AXUIElementGetTypeID() else { return false }
    let appElement = (app as! AXUIElement)
    var focusRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusRef) == .success,
          let focus = focusRef, CFGetTypeID(focus) == AXUIElementGetTypeID() else { return false }
    var element: AXUIElement? = (focus as! AXUIElement)
    var count = 0
    let maxAncestors = 20
    while let el = element, count < maxAncestors {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if role == "AXMenu" || role == "AXMenuItem" { return true }
        }
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        element = (parent as! AXUIElement)
        count += 1
    }
    return false
}

/// True when we should send arrow keys / Return (menu or submenu active).
func useMenuBehavior() -> Bool {
    isMenuMode || isMenuFocused()
}

func enterMenuMode() {
    isMenuMode = true
    menuModeTimeout?.cancel()
    let work = DispatchWorkItem { isMenuMode = false }
    menuModeTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + menuModeTimeoutInterval, execute: work)
}

func exitMenuMode() {
    isMenuMode = false
    menuModeTimeout?.cancel()
    menuModeTimeout = nil
}

driver.onRotate = { delta, _ in
    DispatchQueue.main.async {
        lastRotationTime = CFAbsoluteTimeGetCurrent()
        startThrob()
        if useMenuBehavior() {
            let arrowKey: CGKeyCode = delta > 0 ? kDownArrow : kUpArrow
            for _ in 0 ..< abs(delta) {
                postKey(arrowKey)
            }
            if isMenuMode {
                menuModeTimeout?.cancel()
                let work = DispatchWorkItem { isMenuMode = false }
                menuModeTimeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + menuModeTimeoutInterval, execute: work)
            }
        } else {
            switch rotationMode {
            case .scroll:
                postScroll(delta: delta)
            case .volume:
                volumeAccumulator += Float(delta)
                while volumeAccumulator >= 6 { postVolumeUp(); volumeAccumulator -= 6 }
                while volumeAccumulator <= -6 { postVolumeDown(); volumeAccumulator += 6 }
            }
        }
    }
}

driver.onClick = {
    DispatchQueue.main.async {
        if useMenuBehavior() {
            postKey(kReturnKey)
            // Do not exit menu mode here: a submenu may open and we need to keep sending arrow keys.
            // Menu mode will exit on the 5-second timeout when the user stops rotating.
        } else {
            exitMenuMode()
            performButtonAction(clickAction)
        }
    }
}

driver.onLongPress = {
    enterMenuMode()
    performButtonAction(longPressAction)
}

// Optional: LED feedback (dim when idle, throb while turning, full on when button held).
// LED updates run on a background queue so they never block the main run loop (where HID
// reports are delivered); blocking the main loop was causing scroll to pause then resume.
private let ledQueue = DispatchQueue(label: "com.powermate.agent.led", qos: .utility)
func setLEDOffMain(_ value: UInt8) {
    ledQueue.async { _ = driver.setLEDBrightness(value) }
}

var isButtonDown = false
var lastRotationTime: CFTimeInterval = 0
var throbTimer: DispatchSourceTimer?
var smoothedThrobBrightness: Double = 80
let throbPeriod: CFTimeInterval = 1.5
let throbIdleTimeout: CFTimeInterval = 0.5
let throbTick: CFTimeInterval = 0.025
let throbSmooth: Double = 0.22

func startThrob() {
    lastRotationTime = CFAbsoluteTimeGetCurrent()
    guard throbTimer == nil else { return }
    throbTimer = DispatchSource.makeTimerSource(queue: .main)
    throbTimer?.schedule(deadline: .now(), repeating: throbTick)
    throbTimer?.setEventHandler {
        guard driver.isConnected, !isButtonDown else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRotationTime > throbIdleTimeout {
            throbTimer?.cancel()
            throbTimer = nil
            setLEDOffMain(80)
            smoothedThrobBrightness = 80
            return
        }
        let t = now.truncatingRemainder(dividingBy: throbPeriod) / throbPeriod
        let target = 80 + 175 * (0.5 + 0.5 * sin(t * 2 * .pi))
        smoothedThrobBrightness += (target - smoothedThrobBrightness) * throbSmooth
        let value = UInt8(max(0, min(255, smoothedThrobBrightness.rounded())))
        setLEDOffMain(value)
    }
    throbTimer?.resume()
}

driver.onButtonDown = {
    isButtonDown = true
    setLEDOffMain(255)
}
driver.onButtonUp = {
    isButtonDown = false
    if throbTimer != nil {
        lastRotationTime = CFAbsoluteTimeGetCurrent()
    } else {
        setLEDOffMain(80)
    }
}

driver.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    if driver.isConnected {
        setLEDOffMain(80)
    }
}

// Menu bar: status item and menu with Reverse scroll / Long press options
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class MenuHandler: NSObject, NSMenuDelegate {
    var reverseScrollItem: NSMenuItem!
    var rotationScrollItem: NSMenuItem!
    var rotationVolumeItem: NSMenuItem!
    var clickMouseItem: NSMenuItem!
    var clickRightClickItem: NSMenuItem!
    var clickDoubleClickItem: NSMenuItem!
    var clickMuteItem: NSMenuItem!
    var clickPlayPauseItem: NSMenuItem!
    var longPressMouseItem: NSMenuItem!
    var longPressRightItem: NSMenuItem!
    var longPressDoubleItem: NSMenuItem!
    var longPressMuteItem: NSMenuItem!
    var longPressPlayPauseItem: NSMenuItem!

    func updateMenuState() {
        reverseScrollItem.state = scrollReversed ? .on : .off
        reverseScrollItem.isEnabled = (rotationMode == .scroll)
        rotationScrollItem.state = (rotationMode == .scroll) ? .on : .off
        rotationVolumeItem.state = (rotationMode == .volume) ? .on : .off
        clickMouseItem.state = (clickAction == .mouseClick) ? .on : .off
        clickRightClickItem.state = (clickAction == .rightClick) ? .on : .off
        clickDoubleClickItem.state = (clickAction == .doubleClick) ? .on : .off
        clickMuteItem.state = (clickAction == .mute) ? .on : .off
        clickPlayPauseItem.state = (clickAction == .playPause) ? .on : .off
        longPressMouseItem.state = (longPressAction == .mouseClick) ? .on : .off
        longPressRightItem.state = (longPressAction == .rightClick) ? .on : .off
        longPressDoubleItem.state = (longPressAction == .doubleClick) ? .on : .off
        longPressMuteItem.state = (longPressAction == .mute) ? .on : .off
        longPressPlayPauseItem.state = (longPressAction == .playPause) ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenuState() }

    @objc func toggleScrollReversed() { scrollReversed.toggle(); updateMenuState() }
    @objc func setRotationScroll() { rotationMode = .scroll; updateMenuState() }
    @objc func setRotationVolume() { rotationMode = .volume; updateMenuState() }
    @objc func setClickMouse() { clickAction = .mouseClick; updateMenuState() }
    @objc func setClickRightClick() { clickAction = .rightClick; updateMenuState() }
    @objc func setClickDoubleClick() { clickAction = .doubleClick; updateMenuState() }
    @objc func setClickMute() { clickAction = .mute; updateMenuState() }
    @objc func setClickPlayPause() { clickAction = .playPause; updateMenuState() }
    @objc func setLongPressMouse() { longPressAction = .mouseClick; updateMenuState() }
    @objc func setLongPressRightClick() { longPressAction = .rightClick; updateMenuState() }
    @objc func setLongPressDoubleClick() { longPressAction = .doubleClick; updateMenuState() }
    @objc func setLongPressMute() { longPressAction = .mute; updateMenuState() }
    @objc func setLongPressPlayPause() { longPressAction = .playPause; updateMenuState() }
}

let menuHandler = MenuHandler()
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
if let button = statusItem.button {
    button.image = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "PowerMate Agent")
    button.toolTip = "PowerMate Agent — scroll & click at cursor"
}
let menu = NSMenu()
menu.delegate = menuHandler

let rotationMenu = NSMenu()
let rotScrollItem = NSMenuItem(title: "Scroll", action: #selector(MenuHandler.setRotationScroll), keyEquivalent: "")
rotScrollItem.target = menuHandler
menuHandler.rotationScrollItem = rotScrollItem
rotationMenu.addItem(rotScrollItem)
let rotVolumeItem = NSMenuItem(title: "Volume", action: #selector(MenuHandler.setRotationVolume), keyEquivalent: "")
rotVolumeItem.target = menuHandler
menuHandler.rotationVolumeItem = rotVolumeItem
rotationMenu.addItem(rotVolumeItem)
rotationMenu.addItem(NSMenuItem.separator())
let reverseItem = NSMenuItem(title: "Reverse scroll direction", action: #selector(MenuHandler.toggleScrollReversed), keyEquivalent: "")
reverseItem.target = menuHandler
menuHandler.reverseScrollItem = reverseItem
rotationMenu.addItem(reverseItem)
let rotationSub = NSMenuItem(title: "Rotation", action: nil, keyEquivalent: "")
rotationSub.submenu = rotationMenu
menu.addItem(rotationSub)

func makeButtonActionMenu(
    mouseAction: Selector, rightAction: Selector, doubleAction: Selector,
    muteAction: Selector, playPauseAction: Selector,
    mouseItem: inout NSMenuItem!, rightItem: inout NSMenuItem!,
    doubleItem: inout NSMenuItem!, muteItem: inout NSMenuItem!, playPauseItem: inout NSMenuItem!
) -> NSMenu {
    let m = NSMenu()
    func add(_ title: String, _ sel: Selector, _ item: inout NSMenuItem!) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = menuHandler
        item = i
        m.addItem(i)
    }
    add("Mouse click",  mouseAction,     &mouseItem)
    add("Right-click",  rightAction,     &rightItem)
    add("Double-click", doubleAction,    &doubleItem)
    add("Mute",         muteAction,      &muteItem)
    add("Play / Pause", playPauseAction, &playPauseItem)
    return m
}

let clickMenu = makeButtonActionMenu(
    mouseAction: #selector(MenuHandler.setClickMouse),
    rightAction: #selector(MenuHandler.setClickRightClick),
    doubleAction: #selector(MenuHandler.setClickDoubleClick),
    muteAction: #selector(MenuHandler.setClickMute),
    playPauseAction: #selector(MenuHandler.setClickPlayPause),
    mouseItem: &menuHandler.clickMouseItem,
    rightItem: &menuHandler.clickRightClickItem,
    doubleItem: &menuHandler.clickDoubleClickItem,
    muteItem: &menuHandler.clickMuteItem,
    playPauseItem: &menuHandler.clickPlayPauseItem
)
let clickSub = NSMenuItem(title: "Click", action: nil, keyEquivalent: "")
clickSub.submenu = clickMenu
menu.addItem(clickSub)

let longPressMenu = makeButtonActionMenu(
    mouseAction: #selector(MenuHandler.setLongPressMouse),
    rightAction: #selector(MenuHandler.setLongPressRightClick),
    doubleAction: #selector(MenuHandler.setLongPressDoubleClick),
    muteAction: #selector(MenuHandler.setLongPressMute),
    playPauseAction: #selector(MenuHandler.setLongPressPlayPause),
    mouseItem: &menuHandler.longPressMouseItem,
    rightItem: &menuHandler.longPressRightItem,
    doubleItem: &menuHandler.longPressDoubleItem,
    muteItem: &menuHandler.longPressMuteItem,
    playPauseItem: &menuHandler.longPressPlayPauseItem
)
let longPressSub = NSMenuItem(title: "Long press", action: nil, keyEquivalent: "")
longPressSub.submenu = longPressMenu
menu.addItem(longPressSub)

menu.addItem(NSMenuItem.separator())
let quitItem = NSMenuItem(title: "Quit PowerMate Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
quitItem.target = app
menu.addItem(quitItem)
statusItem.menu = menu
menuHandler.updateMenuState()

app.activate(ignoringOtherApps: true)
app.run()
