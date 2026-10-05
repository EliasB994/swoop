// swoop — Hyprland-style workspace cycling for macOS.
//
// Option+Tab glides to the next Space, Option+Shift+Tab to the previous one,
// wrapping around at the ends. Switching is done by triggering the system's own
// "Move left/right a space" shortcuts, so you get the native slide animation.

import ApplicationServices
import Foundation

// MARK: - Private SkyLight API (read-only, works with SIP enabled)

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

// MARK: - Space layout

let userSpaceType = 0  // regular desktop; 4 = fullscreen app

struct SpaceLayout {
    let ids: [UInt64]
    let types: [Int]
    let currentIndex: Int
    /// Number of regular desktops on displays listed before this one,
    /// used to work out the global "Desktop N" number.
    let desktopOffset: Int

    var count: Int { ids.count }

    /// 1-based "Switch to Desktop N" number for the space at `index`, if it's a regular desktop.
    func desktopNumber(at index: Int) -> Int? {
        guard types[index] == userSpaceType else { return nil }
        return desktopOffset + types[..<index].filter { $0 == userSpaceType }.count + 1
    }
}

func currentLayout() -> SpaceLayout? {
    let cid = CGSMainConnectionID()
    let active = CGSGetActiveSpace(cid)
    guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return nil }

    var desktopsBefore = 0
    for display in displays {
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        let ids = spaces.map { (($0["id64"] ?? $0["ManagedSpaceID"]) as? NSNumber)?.uint64Value ?? 0 }
        let types = spaces.map { ($0["type"] as? NSNumber)?.intValue ?? userSpaceType }
        if let index = ids.firstIndex(of: active) {
            return SpaceLayout(ids: ids, types: types, currentIndex: index, desktopOffset: desktopsBefore)
        }
        desktopsBefore += types.filter { $0 == userSpaceType }.count
    }
    return nil
}

// MARK: - System shortcuts

struct Hotkey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

// IDs in com.apple.symbolichotkeys
let moveLeftSpaceID = 79
let moveRightSpaceID = 81
let desktop1ID = 118  // 118...126 = Switch to Desktop 1...9

// Arrow keys carry the fn + numeric-pad flags; without them the shortcut doesn't fire.
let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
let defaultHotkeys: [Int: Hotkey] = [
    moveLeftSpaceID: Hotkey(keyCode: 123, flags: arrowFlags),
    moveRightSpaceID: Hotkey(keyCode: 124, flags: arrowFlags),
]

/// Reads the user's current binding for a symbolic hotkey. Returns nil if it's disabled.
func symbolicHotkey(_ id: Int) -> Hotkey? {
    let domain = "com.apple.symbolichotkeys" as CFString
    CFPreferencesAppSynchronize(domain)
    let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]

    guard let entry = all?[String(id)] as? [String: Any] else { return defaultHotkeys[id] }
    guard (entry["enabled"] as? NSNumber)?.boolValue == true else { return nil }
    guard let value = entry["value"] as? [String: Any],
          let params = value["parameters"] as? [NSNumber], params.count == 3
    else { return defaultHotkeys[id] }

    return Hotkey(keyCode: CGKeyCode(params[1].intValue), flags: CGEventFlags(rawValue: params[2].uint64Value))
}

func press(_ hotkey: Hotkey) {
    let source = CGEventSource(stateID: .hidSystemState)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: hotkey.keyCode, keyDown: keyDown)
        event?.flags = hotkey.flags
        event?.post(tap: .cghidEventTap)
    }
}

// MARK: - Switching

enum Direction: Int {
    case prev = -1
    case next = 1
}

/// The space index the user has asked for, or nil when idle. Quick repeated taps
/// build on this rather than on the active space, which lags during the slide.
var target: Int?
var driving = false

/// macOS drops shortcut presses that arrive mid-animation, so every step is
/// confirmed against the real active space and retried if nothing happened.
let stepTimeout: TimeInterval = 0.35
let maxAttempts = 3

func swoop(_ direction: Direction) {
    guard let layout = currentLayout(), layout.count > 1 else { return }

    let base = target.flatMap { $0 < layout.count ? $0 : nil } ?? layout.currentIndex
    target = (base + direction.rawValue + layout.count) % layout.count
    if !driving { drive(attempt: 0) }
}

/// Takes one step toward `target`, waits for macOS to actually switch, then repeats.
func drive(attempt: Int) {
    guard let goal = target, let layout = currentLayout(), goal < layout.count,
          layout.currentIndex != goal
    else { return finish() }

    guard attempt < maxAttempts else {
        log("gave up moving from space \(layout.currentIndex + 1) to \(goal + 1)")
        return finish()
    }

    guard pressStep(from: layout.currentIndex, to: goal, in: layout) else { return finish() }
    driving = true

    let deadline = Date().addingTimeInterval(stepTimeout)
    waitForSpaceChange(from: layout.ids[layout.currentIndex], until: deadline) { changed in
        drive(attempt: changed ? 0 : attempt + 1)
    }
}

func finish() {
    driving = false
    target = nil
}

/// Presses the shortcut that best moves from `from` toward `to`.
func pressStep(from: Int, to: Int, in layout: SpaceLayout) -> Bool {
    // Wrapping: jump straight there if "Switch to Desktop N" is enabled.
    if abs(to - from) > 1, let n = layout.desktopNumber(at: to), n <= 9,
       let jump = symbolicHotkey(desktop1ID + n - 1) {
        press(jump)
        return true
    }

    // Otherwise a single native slide toward the target.
    guard let step = symbolicHotkey(to > from ? moveRightSpaceID : moveLeftSpaceID) else {
        log("Move left/right a space shortcuts are disabled in System Settings")
        return false
    }
    press(step)
    return true
}

func waitForSpaceChange(from space: UInt64, until deadline: Date, then done: @escaping (Bool) -> Void) {
    if CGSGetActiveSpace(CGSMainConnectionID()) != space { return done(true) }
    if Date() >= deadline { return done(false) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
        waitForSpaceChange(from: space, until: deadline, then: done)
    }
}

// MARK: - Event tap

let tabKeyCode: Int64 = 48
var eventTap: CFMachPort?

func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    guard type == .keyDown || type == .keyUp,
          event.getIntegerValueField(.keyboardEventKeycode) == tabKeyCode,
          flags.contains(.maskAlternate),
          !flags.contains(.maskCommand),
          !flags.contains(.maskControl)
    else { return Unmanaged.passUnretained(event) }

    // Ignore key repeat so holding Option+Tab doesn't spin through every space.
    if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        let direction: Direction = flags.contains(.maskShift) ? .prev : .next
        DispatchQueue.main.async { swoop(direction) }
    }
    return nil  // swallow Option+Tab so the focused app never sees it
}

func startTap() -> Bool {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, _ in handleEvent(type, event) },
        userInfo: nil
    ) else { return false }

    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

/// Holds an exclusive lock for the life of the process so a second copy
/// (e.g. double-clicking Swoop.app) can't double-switch every tap.
func acquireSingleInstanceLock() -> Bool {
    let fd = open(NSTemporaryDirectory() + "com.elias.swoop.lock", O_CREAT | O_RDWR, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
}

func runDaemon() -> Never {
    guard acquireSingleInstanceLock() else {
        log("Already running")
        exit(0)
    }

    // AXIsProcessTrusted() is cached per process and never flips to true after a
    // grant, so keep retrying the tap itself, which checks permission live.
    if !startTap() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        log("Waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        while !startTap() { Thread.sleep(forTimeInterval: 2) }
    }
    log("Listening for Option+Tab / Option+Shift+Tab")
    CFRunLoopRun()
    exit(0)
}

// MARK: - CLI

func log(_ message: String) {
    FileHandle.standardError.write(Data("swoop: \(message)\n".utf8))
}

func printStatus() {
    guard let layout = currentLayout() else {
        print("Could not read space layout")
        exit(1)
    }
    for i in 0..<layout.count {
        let marker = i == layout.currentIndex ? "▶" : " "
        let name = layout.desktopNumber(at: i).map { "Desktop \($0)" } ?? "Fullscreen app"
        print("\(marker) \(i + 1). \(name)  (id \(layout.ids[i]))")
    }
    let shortcuts = (1...9).filter { symbolicHotkey(desktop1ID + $0 - 1) != nil }
    print("Move left/right a space: \(symbolicHotkey(moveLeftSpaceID) != nil ? "on" : "off")/\(symbolicHotkey(moveRightSpaceID) != nil ? "on" : "off")")
    print("Switch to Desktop N shortcuts enabled: \(shortcuts.isEmpty ? "none" : shortcuts.map(String.init).joined(separator: ", "))")
}

switch CommandLine.arguments.dropFirst().first {
case nil, "run": runDaemon()
case "next", "prev":
    swoop(CommandLine.arguments[1] == "next" ? .next : .prev)
    while driving { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "status": printStatus()
default:
    print("usage: swoop [run | next | prev | status]")
    exit(2)
}
