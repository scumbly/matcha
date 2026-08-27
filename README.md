

# Matcha

<img src="AppIcon.png" width="128" align="right" alt="Matcha app icon">A tiny macOS menu-bar app that keeps your Mac awake on demand — a modern,
fully-supported re-implementation of the classic *Caffeine* menulet.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)

## Features

<img width="283" height="356" alt="matcha-screenshot" src="https://github.com/user-attachments/assets/01dbf065-a150-4aa3-a8b7-fb0a5b1e2a2b" align="right" />

- **Left-click** the cup to toggle keep-awake on/off. The icon fills when active.
- **Right-click** (or ⌃-click) for a menu: choose a duration, toggle Start at
  Login / the global hotkey / low-battery cutoff, or open About.
- **Durations** — Indefinitely / 15 min / 1 hour / 4 hours / 8 hours. Your
  choice **persists** across launches and is what left-click uses.
- **Global hotkey (⌃⌘M)** — optional, toggles Matcha from any app. Uses Carbon
  `RegisterEventHotKey`, so it needs no Accessibility permission.
- **Disable on low battery** — when running on battery or UPS at/below 10%,
  Matcha suppresses keep-awake and resumes automatically once mains power
  returns or charge climbs back above 10%. The menu item only appears if you
  actually have a battery or an attached UPS.
- The menu-bar glyph is custom-drawn and adapts to light and dark menu bars.

## Requirements

macOS 13 (Ventura) or later, Apple silicon or Intel.

## Install

The app is not Apple notarized, so you'll need to approve it so Gatekeeper 
does not block it. Any **one** of these 3 approaches will accomplish this:

**Why there's a prompt at all:** these builds are **ad-hoc signed, not
notarized** — I don't pay for an Apple Developer account. When you download a
file, your browser attaches an extended attribute called `com.apple.quarantine`
to it. Gatekeeper sees that flag on an app it can't verify with Apple and
refuses the first launch, calling it "from an unidentified developer." Each
option below is a different way of dealing with that flag.

### Option A — download and approve it in System Settings

No terminal required.

1. Grab the latest zip from [Releases](https://github.com/scumbly/matcha/releases),
   unzip it, and drag `Matcha.app` to your Applications folder.
2. Double-click Matcha. It gets blocked — that's expected.
3. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to the Matcha message. Confirm with Touch ID or your
   password.

macOS remembers the approval, so this is a one-time step.

> On macOS 15 (Sequoia) and later, right-clicking the app and choosing **Open**
> no longer bypasses Gatekeeper. System Settings is the only route that works.

### Option B — download and clear the quarantine flag yourself

Fastest option if you're comfortable at a command line and you want the
prebuilt binary rather than to compile it. Download and unzip as above, drag
`Matcha.app` to Applications, then:

```sh
xattr -dr com.apple.quarantine /Applications/Matcha.app
```

`-d` deletes the named attribute, `-r` recurses through everything inside the
bundle.

### Option C — build it yourself

**No Gatekeeper step at all.** A binary you compile locally never gets a
quarantine attribute, because it didn't come from a browser — so there's
nothing to approve or strip.

Requires only the Xcode Command Line Tools (`xcode-select --install`). No Xcode
project, package manager, or dependencies.

```sh
git clone https://github.com/scumbly/matcha.git
cd matcha
./build.sh --install
```

That compiles `main.swift`, assembles the bundle, ad-hoc-signs it, and copies
the result to `~/Applications`. Drop `--install` to leave it in `build/` and
place it yourself. It takes a few seconds.

The version is derived from the nearest git tag (`v1.11` becomes `1.11`; three
commits past it becomes `1.11.3`), and is stamped into the built bundle only —
building never modifies a tracked file, so your working tree stays clean.
Override it with `MATCHA_VERSION=1.2.3 ./build.sh`.

## How it works

Matcha holds an IOKit power assertion of type `PreventUserIdleDisplaySleep` —
the same mechanism as `caffeinate -d`, but in-process, so there's no child
process to manage. Timed activations auto-release via a `Timer`. Launch-at-login
uses `SMAppService` (macOS 13+). The global hotkey uses Carbon
`RegisterEventHotKey`. Low-battery detection uses IOKit power-source
notifications (`IOPSNotificationCreateRunLoopSource`).

Matcha prevents *display* sleep — the screen stays on — matching Caffeine's
behaviour rather than `caffeinate -i`.

## Files

| File | Purpose |
|------|---------|
| `main.swift`      | The entire app (AppKit `NSStatusItem` + IOKit). |
| `AppIcon.png`     | Source artwork; `build.sh` scales it into the `.icns`. |
| `Info.plist`      | Bundle metadata (`LSUIElement` agent, min macOS 13). |
| `build.sh`        | Compile → bundle → sign. |
| `VERSION`         | Fallback version for source tarballs (no git metadata). |

## License

Matcha is free software, licensed under the
[GNU General Public License v3.0 or later](LICENSE).

It comes with ABSOLUTELY NO WARRANTY. You may redistribute and modify it under
the terms of that license.
