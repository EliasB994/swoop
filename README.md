# swoop

**Hyprland-style workspace cycling for macOS.** Glide through your Spaces with
`⌥ Tab`, the way `SUPER + Tab` works on Hyprland, with the same native slide
animation you get from a three-finger trackpad swipe.

<!-- TODO: add a demo GIF here, e.g. ![demo](docs/demo.gif) -->

| Shortcut | Action |
|---|---|
| `⌥ Tab` | Next Space (wraps from the last to the first) |
| `⌥ ⇧ Tab` | Previous Space (wraps from the first to the last) |

## Why

macOS can already move between Spaces with `⌃ ←` / `⌃ →`, but it stops at the
ends and can't be put on a single cycling key. swoop adds that cycle without
replacing Mission Control and without disabling System Integrity Protection.

## Features

- **Native animation.** swoop triggers macOS's own "Move left/right a space"
  shortcuts, so switching looks and feels like the trackpad gesture.
- **Wrap-around** in both directions.
- **Rapid tapping.** Hold `⌥` and tap `Tab` repeatedly; every step is checked
  against the real active Space, so it never gets out of sync.
- **Multi-display aware.** It cycles the Spaces of the display you're on,
  fullscreen apps included.
- **SIP stays on.** It only reads Space information through private APIs and
  never modifies anything.
- **Tiny.** One Swift file and no dependencies. It runs as a background
  LaunchAgent with no Dock icon.

## Requirements

- macOS on Apple Silicon or Intel. Developed and tested on macOS 26 (Tahoe);
  earlier versions are untested.
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`.
- Mission Control's **Move left a space** / **Move right a space** shortcuts
  enabled (they're on by default).

## Installation

```sh
git clone https://github.com/EliasB994/swoop.git
cd swoop
make install
```

`make install` builds `build/Swoop.app`, installs a LaunchAgent so swoop starts
at login, and links the `swoop` command into your Homebrew `bin` directory
(override with `make install BINDIR=/some/dir`).

### Grant Accessibility permission

swoop needs Accessibility access to capture `⌥ Tab` and send the switch
shortcut:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Click **+**, choose `build/Swoop.app` from the cloned folder, and turn it on.
3. swoop picks up the permission within a couple of seconds. Check with
   `make logs`; you should see `Listening for Option+Tab / Option+Shift+Tab`.

### Recommended: faster wrap-around

Enable **System Settings → Keyboard → Keyboard Shortcuts → Mission Control →
Switch to Desktop 1–9**. swoop then jumps straight to the first or last desktop
in a single slide when wrapping, instead of gliding back across every Space.

## Usage

Once installed, just press `⌥ Tab`. From the terminal:

```sh
swoop status   # list Spaces on the active display and which shortcuts are enabled
swoop next     # switch once (the terminal app itself needs Accessibility access)
swoop prev
```

Make targets:

| Command | Description |
|---|---|
| `make install` | Build, install the LaunchAgent and link the `swoop` command |
| `make uninstall` | Stop swoop and remove the LaunchAgent and command link |
| `make restart` | Restart the background agent |
| `make logs` | Follow `~/Library/Logs/swoop.log` |
| `make run` | Run in the foreground (stop the agent first) |
| `make clean` | Remove build output |

## How it works

1. A `CGEventTap` captures `⌥ Tab` / `⌥ ⇧ Tab` and swallows it, so the focused
   app never sees it. Key repeat is ignored.
2. Private, read-only SkyLight calls (`CGSGetActiveSpace`,
   `CGSCopyManagedDisplaySpaces`) give the current Space and the ordered list of
   Spaces on the active display.
3. Each tap moves a *target* Space one step. swoop then presses your configured
   shortcut ("Move left/right a space", or "Switch to Desktop N" when wrapping)
   one step at a time. After each step it waits until macOS has actually switched
   and retries if the press was dropped mid-animation.

Shortcut bindings are read from `com.apple.symbolichotkeys`, so swoop also works
if you've rebound them.

## Troubleshooting

**`⌥ Tab` does nothing, and the log says "Waiting for Accessibility permission".**
swoop is ad-hoc signed, so macOS ties the permission to that exact build. After
rebuilding, the existing **Swoop** entry in Settings no longer matches and turning
it on has no effect. Select it, remove it with **−**, add `build/Swoop.app` again
with **+**, then run `make restart`.

**Wrapping glides through every Space.** Enable the *Switch to Desktop N*
shortcuts (see [Recommended: faster wrap-around](#recommended-faster-wrap-around)).
Wrapping to a fullscreen app always glides, because macOS has no direct shortcut
for those.

**An app needs `⌥ Tab` itself.** swoop currently captures it globally.

## Limitations

- Relies on undocumented SkyLight APIs, which a future macOS release could change.
- The shortcut is fixed to `⌥ Tab` for now.
- Quick taps can occasionally lag about 0.35 s while swoop retries a press
  macOS dropped during an animation.

## Roadmap

- [ ] Configurable shortcut
- [ ] On-screen workspace indicator overlay
- [ ] Faster, trackpad-like glide via synthesized swipe gestures
- [ ] Homebrew tap and signed release builds

## Contributing

Issues and pull requests are welcome. swoop is deliberately small: one Swift
file, no dependencies, no Xcode project. Please keep it that way where you can.

## Acknowledgements

Inspired by [Hyprland](https://hyprland.org)'s workspace cycling.

## License

[MIT](LICENSE) © 2026 Elias Bielskis
