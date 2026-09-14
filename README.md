# Cuety

A macOS cue display for [QLab](https://qlab.app). Cuety connects to a QLab workspace over
OSC and shows the playhead's current cue at a size that reads from across a room — for the
operator watching a monitor at the desk, or a display in the wings.

It is a read-only companion, not a remote control: Cuety watches a show, it does not fire
cues.

## What it does

- **Finds QLab automatically.** Bonjour discovery of `_qlab._tcp` on the local network,
  with manual host entry for machines Bonjour can't reach.
- **Shows the cue that matters.** The current cue number and name at display scale, with
  configurable detail pills beneath it — type, duration, pre- and post-wait, continue
  mode, cue list, armed, flagged, and notes.
- **Presentation mode** (⇧⌘F) hides all chrome for an unattended display.
- **Keep display awake** is a separate, persisted setting that holds off the screensaver
  for as long as it's on.
- **Cue drawer** (⌥⌘D) shows the watched cue list around the playhead for context.
- **Activity Log** (⇧⌘L) records the OSC conversation, with passcodes redacted.
- **Connection Status** (⇧⌘I) exposes heartbeat and session state when something looks
  wrong.
- **Passcode-protected workspaces** are supported; passcodes are stored in the Keychain,
  never in preferences.

## Requirements

- macOS 27 or later
- Xcode 27 or later (Swift 6, `MainActor` default isolation)
- QLab reachable on the local network

## Building

Open `Cuety.xcodeproj` and build the `Cuety` scheme, or:

```sh
xcodebuild -project Cuety.xcodeproj -scheme Cuety -configuration Debug build
```

Tests use the [Swift Testing](https://developer.apple.com/documentation/testing/) framework:

```sh
xcodebuild -project Cuety.xcodeproj -scheme Cuety test
```

### Running it on another Mac

The app is currently signed ad-hoc (no Developer ID, hardened runtime off), so a build
copied to another machine is blocked by Gatekeeper until its quarantine flag is cleared:

```sh
xattr -dr com.apple.quarantine /Applications/Cuety.app
```

Distribute a **Release** build, not the Debug build from DerivedData — the latter carries
the `get-task-allow` entitlement and is built for the active architecture only.

On first launch each machine will ask to use the local network. Declining it leaves Bonjour
discovery finding nothing.

## Project layout

| Path | Contents |
|---|---|
| `Cuety/App` | App entry point and menu bar commands |
| `Cuety/Features` | One folder per surface — display, drawer, sidebar, settings, logs |
| `Cuety/Model` | `AppModel`, cue graph, preferences, activity log |
| `Cuety/Networking` | QLab session, Bonjour browser, Keychain passcode store |
| `Cuety/OSC` | OSC encoding/decoding and SLIP framing |
| `Cuety/System` | Display sleep blocking |
| `CuetyTests` | Protocol, session, and model tests |
| `POLISH_PLAN.md` | Pre-release polish tracking — open work items live here |

## Licence

MIT — see [LICENSE](LICENSE). Do what you like with it; keep the copyright notice.
