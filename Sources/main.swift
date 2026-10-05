// swoop — Hyprland-style workspace cycling for macOS.
//
// Option+Tab glides to the next Space, Option+Shift+Tab to the previous one,
// wrapping around at the ends. Switching is done with synthesized trackpad
// swipes (fast, tunable slide) or the system's own "Move left/right a space"
// shortcuts (native slide), depending on the `speed` setting.

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

// MARK: - Synthesized trackpad swipes (undocumented CGEvent fields)

enum GestureField: UInt32 {
    case eventType = 55
    case hidType = 110
    case scrollY = 119
    case swipeMotion = 123
    case swipeProgress = 124
    case swipeVelocityX = 129
    case phase = 132
    case flagBits = 135
    case zoomDeltaX = 139
}

let gestureEventType: Int64 = 29
let dockControlEventType: Int64 = 30
let dockSwipeHIDType: Int64 = 23
let horizontalMotion: Int64 = 1
let phaseBegan: Int64 = 1
let phaseEnded: Int64 = 4

extension CGEvent {
    func set(_ field: GestureField, _ value: Int64) {
        setIntegerValueField(CGEventField(rawValue: field.rawValue)!, value: value)
    }

    func set(_ field: GestureField, _ value: Double) {
        setDoubleValueField(CGEventField(rawValue: field.rawValue)!, value: value)
    }
}

/// Posts a one-space horizontal Dock swipe, as if flicked on the trackpad.
/// macOS finishes the slide faster the higher the release velocity.
func swipe(right: Bool, velocity: Double) {
    for phase in [phaseBegan, phaseEnded] {
        guard let dock = CGEvent(source: nil), let gesture = CGEvent(source: nil) else { return }
        dock.set(.eventType, dockControlEventType)
        dock.set(.hidType, dockSwipeHIDType)
        dock.set(.phase, phase)
        dock.set(.flagBits, Int64(right ? 1 : 0))
        dock.set(.swipeMotion, horizontalMotion)
        dock.set(.scrollY, 0.0)
        dock.set(.zoomDeltaX, Double(Float.leastNonzeroMagnitude))
        if phase == phaseEnded {
            dock.set(.swipeProgress, right ? 1.0 : -1.0)
            dock.set(.swipeVelocityX, right ? velocity : -velocity)
        }
        dock.post(tap: .cgSessionEventTap)

        gesture.set(.eventType, gestureEventType)
        gesture.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Settings

/// How a switch looks, set with `defaults write com.elias.swoop speed <value>`
/// and read on every tap, so changes apply without a restart:
///   fast     quick slide (~150 ms), the default
///   instant  no visible slide (~50 ms)
///   native   the system shortcut's own slide (~0.6–1.2 s)
///   <number> raw swipe velocity: ≤50 is a normal-speed slide, ~40 moderately fast, ≥80 instant
enum Speed {
    case native
    case swipe(velocity: Double)
}

let fastVelocity = 40.0
let instantVelocity = 200.0

func currentSpeed() -> Speed {
    let domain = "com.elias.swoop" as CFString
    CFPreferencesAppSynchronize(domain)
    switch CFPreferencesCopyAppValue("speed" as CFString, domain) {
    case let number as NSNumber:
        return .swipe(velocity: number.doubleValue)
    case let text as String:
        switch text.lowercased() {
        case "native": return .native
        case "instant": return .swipe(velocity: instantVelocity)
        default: return .swipe(velocity: Double(text) ?? fastVelocity)
        }
    default:
        return .swipe(velocity: fastVelocity)
    }
}

// MARK: - Switching

enum Direction: Int {
    case prev = -1
    case next = 1
}

/// macOS only reports the new active space once a slide settles. It queues further
/// switches sent mid-slide, but drops a keyboard-shortcut reversal (swipes are fine).
/// So swoop tracks two things itself:
/// - `target`: where the user wants to end up; every tap moves it one step.
/// - `inFlight`: where macOS will land once the presses already sent finish.
var target: UInt64?
var inFlight: (id: UInt64, direction: Int, pressedAt: Date)?
var flushScheduled = false
/// Assume macOS has settled after this long, in case a press was dropped.
let settleTimeout: TimeInterval = 2.0
let settlePollInterval: TimeInterval = 0.05

func swoop(_ direction: Direction) {
    guard let layout = currentLayout(), layout.count > 1 else { return }
    refreshInFlight(layout)

    let busy = inFlight != nil || flushScheduled
    let from = busy ? target.flatMap { layout.ids.firstIndex(of: $0) } ?? layout.currentIndex : layout.currentIndex
    target = layout.ids[(from + direction.rawValue + layout.count) % layout.count]
    flush()
}

/// Clears `inFlight` once macOS reports arriving there (or it's clearly not going to).
func refreshInFlight(_ layout: SpaceLayout) {
    guard let f = inFlight else { return }
    if f.id == layout.ids[layout.currentIndex] || !layout.ids.contains(f.id)
        || Date().timeIntervalSince(f.pressedAt) > settleTimeout {
        inFlight = nil
    }
}

/// Sends the switches that take macOS from where it's already heading to `target`.
/// With keyboard shortcuts, a change of direction waits for the current slide to settle.
func flush() {
    flushScheduled = false
    guard let goal = target, let layout = currentLayout(), let to = layout.ids.firstIndex(of: goal) else {
        target = nil
        inFlight = nil
        return
    }
    refreshInFlight(layout)

    let from = inFlight.flatMap { layout.ids.firstIndex(of: $0.id) } ?? layout.currentIndex
    guard from != to else { return }
    let direction = to > from ? 1 : -1

    let speed = currentSpeed()
    if case .native = speed, let f = inFlight, f.direction != direction {
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settlePollInterval) { flush() }
        return
    }

    guard move(from: from, to: to, in: layout, speed: speed) else { return }
    inFlight = (goal, direction, Date())
}

/// Sends the swipes or shortcuts that take macOS from space `from` to space `to`.
func move(from: Int, to: Int, in layout: SpaceLayout, speed: Speed) -> Bool {
    let steps = abs(to - from)

    if case .swipe(let velocity) = speed {
        // More than one step only happens when wrapping: do it instantly. macOS
        // queues back-to-back swipes, so the whole wrap lands in ~60 ms.
        for _ in 0..<steps { swipe(right: to > from, velocity: steps > 1 ? instantVelocity : velocity) }
        return true
    }

    // Wrapping: jump straight there if "Switch to Desktop N" is enabled.
    if abs(to - from) > 1, let n = layout.desktopNumber(at: to), n <= 9,
       let jump = symbolicHotkey(desktop1ID + n - 1) {
        press(jump)
        return true
    }

    // Otherwise native slides; macOS queues them, so a wrap glides across every space.
    guard let step = symbolicHotkey(to > from ? moveRightSpaceID : moveLeftSpaceID) else {
        log("Move left/right a space shortcuts are disabled in System Settings")
        return false
    }
    for _ in 0..<steps { press(step) }
    return true
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
    switch currentSpeed() {
    case .native: print("Speed: native (keyboard shortcuts)")
    case .swipe(let velocity): print("Speed: swipe velocity \(velocity)")
    }
    print("Switch to Desktop N shortcuts enabled: \(shortcuts.isEmpty ? "none" : shortcuts.map(String.init).joined(separator: ", "))")
}

switch CommandLine.arguments.dropFirst().first {
case nil, "run": runDaemon()
case "next", "prev":
    swoop(CommandLine.arguments[1] == "next" ? .next : .prev)
case "status": printStatus()
default:
    print("usage: swoop [run | next | prev | status]")
    exit(2)
}
