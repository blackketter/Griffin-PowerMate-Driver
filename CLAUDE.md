# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and run

```bash
swift build                        # build all targets
swift run PowerMateDemo            # print events from a connected PowerMate (Ctrl+C to stop)
swift run PowerMateAgent           # run the system-wide menu-bar agent
swift build -c release             # release build
```

To build a universal app bundle (arm64 + x86_64) for distribution:

```bash
./scripts/build-app.sh             # produces .build/release/PowerMate Agent.app
./scripts/build-and-package.sh     # build + sign + DMG + notarize + staple (requires secrets.json)
```

`secrets.json` is gitignored. Copy `secrets.json.example` and fill in `developer_id_cert`, `apple_id`, `team_id`, `app_specific_password` before running the packaging script.

## Architecture

Four targets in `Package.swift`:

| Target | Type | Purpose |
|---|---|---|
| `CPowerMateLED` | C library | USB vendor control requests to drive the blue LED (brightness, pulse modes). Links IOKit + CoreFoundation. |
| `PowerMateDriver` | Swift library | Core HID driver — opens the device, reads 6-byte reports, fires typed events. |
| `PowerMateDemo` | Executable | Terminal demo that prints events and animates the LED. Useful for debugging. |
| `PowerMateAgent` | Executable | Menu-bar app that maps PowerMate input to system-wide CGEvents. Links CoreGraphics + AppKit + ApplicationServices. |

### PowerMateDriver (the library)

`PowerMateDriver.swift` matches Griffin PowerMate (VID `0x077d`, PID `0x0410`) via `IOHIDManager`, seizes the device with `kIOHIDOptionsTypeSeizeDevice` (exclusive access — only one process at a time), and dispatches events on the main queue.

Events: `buttonDown`, `buttonUp`, `buttonClick` (short press), `buttonLongPress` (≥ `longPressThreshold`, default 0.4 s), `rotate(delta:rate:)`. Consumers use either closures (`onRotate`, `onClick`, `onLongPress`, …) or the `PowerMateDriverDelegate` protocol.

LED is controlled via `CPowerMateLED` (C wrapper around `IOUSBDeviceInterface` vendor control requests). **LED calls must be dispatched to a background queue** — calling them on the main run loop blocks HID report delivery and causes scroll stuttering.

### PowerMateAgent (the app)

Runs as `LSUIElement` (menu-bar only, no Dock icon) using `NSApplication` with `.accessory` activation policy.

Menu behavior: when a menu or submenu is focused, rotation sends Up/Down arrow keys and click sends Return. Detection uses the Accessibility API (`AXUIElement` ancestor walk). A fallback "menu mode" (5-second timeout) is used when Accessibility is not granted. Long-press enters menu mode and also fires the configured action (right-click or double-click).

### macOS permissions required

- **Input Monitoring** — required to seize the HID device and post `CGEvent`s. macOS prompts on first run.
- **Accessibility** — optional but needed for submenu detection without sticky menu mode.

## Hardware protocol

- Byte 0: button state (`0` = released, `1` = pressed)
- Byte 1: signed rotation delta (`Int8`; positive = clockwise, negative = counter-clockwise, typically ±1–7)
- Bytes 2–5: unused
- Rotation rate (deltas/sec) is derived by the driver from report timing; `nil` on first report.
