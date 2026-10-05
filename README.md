# swoop

**Hyprland-style workspace cycling for macOS.** Glide through your Spaces with
`⌥ Tab`, the way `SUPER + Tab` works on Hyprland, using the same slide you get
from a three-finger trackpad swipe, only faster.

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

- **Fast native slide.** swoop drives Mission Control with synthesized trackpad
  swipes, so switching uses the real Spaces animation, just quicker: about
  170 ms by default, or instant if you prefer.
- **Instant wrap-around** in both directions. Going from the last Space back to
  the first takes about 60 ms.
- **Rapid tapping.** Hold `⌥` and tap `Tab` as fast as you like, wrapping
  included; swoop tracks where macOS is heading so it never gets out of sync.
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

### Choosing the speed

```sh
defaults write com.elias.swoop speed fast      # quick slide, ~170 ms (default)
defaults write com.elias.swoop speed instant   # no visible slide, ~50 ms
defaults write com.elias.swoop speed native    # macOS's own shortcut slide, ~0.6–1.2 s
defaults write com.elias.swoop speed 50        # fine-tune: raw swipe velocity
```

Changes apply on the next tap; no restart needed. For fine-tuning, the
velocity-to-duration curve is steep: about 50 gives a ~0.5 s slide, 53 about
170 ms, 57 about 115 ms, and 80 or more is effectively instant.

`native` uses the **Move left/right a space** keyboard shortcuts instead of
swipes. It's a fallback in case a macOS update breaks the synthesized swipes.
In that mode, enabling **Keyboard Shortcuts → Mission Control → Switch to
Desktop 1–9** lets wraps jump straight to a desktop.

## Usage

Once installed, just press `⌥ Tab`. From the terminal:

```sh
swoop status   # list Spaces on the active display, the speed, and which shortcuts are enabled
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
3. Each tap moves a *target* Space one step, and swoop posts a synthesized
   horizontal Dock swipe (the event a three-finger trackpad swipe produces) with
   a release velocity set by `speed`. A higher velocity makes macOS finish the
   slide faster.
4. macOS queues back-to-back swipes, so a wrap is sent as one instant burst of
   swipes. macOS only reports the new Space once a slide settles, so swoop keeps
   track of where it's heading itself; rapid taps never get out of sync.

In `native` mode swoop presses your "Move left/right a space" (or "Switch to
Desktop N") shortcuts instead, read from `com.apple.symbolichotkeys` so rebound
keys still work. macOS drops a shortcut press that reverses direction mid-slide,
so in this mode a wrap waits for the current slide to finish.

## Troubleshooting

**`⌥ Tab` does nothing, and the log says "Waiting for Accessibility permission".**
Make sure **Swoop** is on in Accessibility. If it already is, the entry may come
from an older build that macOS no longer matches. Remove it with **−**, add
`build/Swoop.app` again with **+**, and run `make restart`. Builds are signed
with a stable identity, so this shouldn't be needed again after rebuilding.

**Switching stopped working after a macOS update.** The synthesized swipes rely on
undocumented event fields. Try `defaults write com.elias.swoop speed native`
and please open an issue.

**An app needs `⌥ Tab` itself.** swoop currently captures it globally.

## Limitations

- Relies on undocumented SkyLight APIs and gesture event fields, which a future
  macOS release could change (`native` mode avoids the gesture fields).
- The shortcut is fixed to `⌥ Tab` for now.
- In `native` mode, wrapping in the middle of fast tapping waits for the current
  slide to finish before heading back the other way.

## Roadmap

- [ ] Configurable shortcut
- [ ] On-screen workspace indicator overlay
- [x] Faster, trackpad-like glide via synthesized swipe gestures
- [ ] Homebrew tap and signed release builds

## Contributing

Issues and pull requests are welcome. swoop is deliberately small: one Swift
file, no dependencies, no Xcode project. Please keep it that way where you can.

## Acknowledgements

Inspired by [Hyprland](https://hyprland.org)'s workspace cycling.

## License

[MIT](LICENSE) © 2026 Elias Bielskis
