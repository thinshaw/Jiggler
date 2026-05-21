# Jiggler

Lightweight macOS menu-bar app that simulates occasional activity (mouse move, scroll, or key press) after a configurable idle threshold.

## Why this exists

Some apps (for example Teams) can mark you idle aggressively. Jiggler is a local utility that helps keep status from flipping while you are still at your machine.

## Features

- Menu bar app (no dock icon)
- Randomized action interval (1-4 minutes)
- Configurable idle threshold before any action runs
- Multiple action methods:
  - Mouse move
  - Scroll
  - Key press (Shift)
- Randomized method order
- Optional auto-stop at a specific time
- Optional auto-stop under battery threshold
- Launch at login toggle
- Accessibility permission self-check + prompt

## Build details (current release)

Artifact:
- `build/Jiggler.dmg`

Build environment:
- macOS 26.5 (25F71)
- Xcode 26.5 (17F42)
- Swift 6.3.2
- Deployment target: macOS 13.0+
- Architecture: arm64

Signing/notarization status:
- Code signature: ad-hoc
- Team ID: not set
- Gatekeeper (`spctl`) assessment: rejected (expected until Developer ID signing + notarization)

SHA-256:
- `1848e73a854be5914fc65e7418dee219fff338f6a07f0b7241e78fd5e9faf06d`  `Jiggler.dmg`

## Install and run

1. Download `Jiggler.dmg` from Releases.
2. Drag `Jiggler.app` into `Applications`.
3. Launch Jiggler.
4. Grant Accessibility permission when prompted:
   - System Settings -> Privacy & Security -> Accessibility -> enable Jiggler

Note: because this build is currently ad-hoc signed, macOS may require extra confirmation steps to open it.

## Build from source

Requirements:
- Xcode 26+
- `xcodegen`
- `create-dmg`

Install helpers:

```bash
brew install xcodegen create-dmg
```

Build + package:

```bash
./make_dmg.sh
```

Manual build:

```bash
xcodegen generate
xcodebuild -project Jiggler.xcodeproj -scheme Jiggler -configuration Release -derivedDataPath build
```

## Project structure

- `Sources/Jiggler/` - SwiftUI app + jiggle engine
- `project.yml` - XcodeGen project definition
- `make_dmg.sh` - release DMG build script

## Security and privacy notes

- Jiggler runs locally on your Mac.
- It uses Accessibility APIs to post synthetic input events.
- It does not include network features in this project.

## Disclaimer

Use responsibly and in line with your workplace policies.
