# Bambu Bar

[bambubar.app](https://bambubar.app) · [Support the project for $9.99](https://bambubar.app/download) to enable automatic updates and receive the Hero Supporter badge.

![Bambu Bar window touring three pages: the Printer page with a turning 3D P2S printing in gold PLA Silk+ at 65% with time left, controls, temperatures and fans; the Filament page with Bambu Lab spools by colour name and grams left, a SUNLU spool and the external spool; and All Printers, six printers with the paused one first](.github/assets/showcase.webp)

<p align="center">
  <img src=".github/assets/menubar.webp" width="600" alt="Animated menu bar item showing 66% and 54 minutes left, with its panel open: the 3D printer model, progress, temperatures and AMS spools in grams; the print pauses because the filament ran out, then the panel switches to the list of all six printers">
</p>

**Your Bambu Lab printer, one click away in the menu bar.**

> **This fork gets its data from a [Bambuddy](https://wiki.bambuddy.cool) server** instead of connecting to each printer itself. Point it at your Bambuddy server with an API key and every printer Bambuddy manages shows up; status comes from Bambuddy's REST API and WebSocket, and pause, resume, stop, speed and light commands go through it too.

Bambu Bar is a native macOS app that shows your 3D printer's progress, temperatures and filament without opening Bambu Studio or Bambu Handy. Glance at the menu bar for percent and time left, click for everything else, or keep a widget on your desktop.

Built with Swift and SwiftUI. Printer data stays local, with no app analytics. The GitHub build is free to use. Optional supporter licenses enable automatic updates; the Mac App Store edition is independent.

[Getting started](#getting-started) · [Features](#features) · [Widgets](#desktop-widgets) · [Compatibility](#compatibility) · [Building](#building-from-source)

> Independent, community-developed software. Not affiliated with or endorsed by Bambu Lab. A P2S is the development printer; other Bambu Lab printers that speak the same LAN protocol (X1, P1, A1, H2) should work.

## Why this app?

The printer is in another room, and the slicer is a big app to keep open just to see how long is left. Bambu Bar keeps the answer in the menu bar: **64% · 1h 02m**. Click it and a panel shows the job, the stage, temperatures, the spool in use and how much filament is left, with pause, stop, light and speed controls right there.

It reads everything from your own Bambuddy server, which already keeps a connection to each printer, so nothing goes through a cloud and the Mac never needs the printers' access codes.

## Features

| | What you get |
| --- | --- |
| **Menu bar** | A printer glyph that fills as the print grows, with progress and time left beside it (or just one, or only the icon), and a pause or alert mark when the printer needs you. |
| **Panel** | The job, its stage ("Heating hotend", "Paused: filament ran out"), percentage, layers, time left and finish time; nozzle, bed and chamber temperatures; AMS spools with what's left and the humidity; printer errors in plain words, in Bambu Lab's own translation. |
| **Filament left** | What's left on each spool as a percentage. (Bambuddy doesn't pass on the spool weight from the RFID tag, so this fork can't show grams.) |
| **Named filament** | Bambu Lab spools show their colour by name (Grass Green, Charcoal). Other spools show the maker and product of the preset you set the slot to on the printer or in Bambu Studio, such as SUNLU PLA Matte. |
| **Controls** | Pause, resume, stop (with a confirmation), print speed (Silent, Standard, Sport, Ludicrous) and a chamber light switch. |
| **3D printer models** | Each printer family is modelled in Blender: the P2S/P1S/X1 enclosure, the wider dual-nozzle H2, the open P1P frame, the A1's arch with its AMS Lite, the A1 mini. In the app it's a live 3D model you can turn with the mouse: the print grows layer by layer in the filament's colour, the bed drops (or the A1's gantry rises) as it goes, the toolhead moves while printing, the AMS spools take their real colours and the chamber light follows the printer's. Widgets use studio renders of the same models. |
| **Knows your model** | What each model has comes from the printer profiles Bambu Lab publishes with Bambu Studio, so you only see what your printer can report: no chamber temperature on an A1 or P1S, no door or chamber light on the A series, both nozzles on an H2D, heated-chamber targets on the H2 and X1E, and the build volume and fans on the Printer page. |
| **Window** | A larger view plus fans, nozzle, door, network, storage and firmware; a Filament page with every spool; a Widgets page that tours every widget size and state. |
| **Many printers** | Bambu Bar watches all of them at once. **All Printers** in the window and the grid button in the panel list every printer, the ones that need you first (failed, paused), then by soonest finish. Switch from the printer name at the top of the panel or the window's sidebar, and choose which one the menu bar shows (or let it pick whichever is busy). |
| **Desktop widgets** | Small, medium and large, one per printer if you like, counting down between updates. |
| **Notifications** | Print finished, failed or canceled, paused (filament runout and the like), new printer errors, and optionally when a print starts. |
| **Easy setup** | Enter your Bambuddy server's address and an API key. Every printer Bambuddy has shows up, and the list follows Bambuddy: printers added or removed there appear or disappear here. |
| **Mac integration** | Open at Login, no Dock icon while it lives in the menu bar (the icon and menus appear while its window is open), keyboard shortcuts. |
| **17 languages** | English, Čeština, Deutsch, Español, Français, Italiano, Magyar, Nederlands, Polski, Português (Brasil), Svenska, Türkçe, Русский, Українська, 日本語, 한국어, 简体中文 and 繁體中文. It follows your Mac's language, or the one picked in **Settings → Language**. Printer terms follow Bambu Studio's translations, and printer errors use Bambu Lab's own texts where Bambu publishes them (all but Czech, Turkish and Ukrainian, which show them in English, and Traditional Chinese, which shows the Simplified ones). |
| **Updates** | The App Store version updates through the App Store. Direct copies with an active website supporter license check GitHub once a day for a new release (turn it off in Settings) and show what's new with **Install Update**, **Skip This Version** or **Remind Me Later**; installing downloads it, verifies its signature and restarts the app. **Check for Updates…** in the app menu asks right away, and Settings can install updates automatically. |

## Getting started

### Requirements

- **macOS 26 Tahoe or later**, Apple silicon or Intel.
- A [Bambuddy](https://wiki.bambuddy.cool) server that manages your printers, reachable from the Mac over http or https, and an API key for it.

### Install and connect

1. Get the ZIP from the latest GitHub release, unzip it, and move **Bambu Bar.app** to Applications. No license is needed to use the app. To enable automatic updates, [support the project for $9.99](https://bambubar.app/download) and enter your key in **Bambu Bar → Manage License…**. In-app checks for the latest GitHub release require an active website supporter license. The Mac App Store edition is distributed separately.
2. In Bambuddy open **Settings → API Keys** and create a key. **Read status** is enough to watch the printers; turn on **Control printer** as well if you want pause, resume, stop, speed and the chamber light from Bambu Bar.
3. Open Bambu Bar and enter the server's address (the one you open Bambuddy at in a browser, such as `http://192.168.1.10:8000`) and the key. If the server is on your local network and macOS asks whether Bambu Bar may find devices on it, click **Allow**.
4. Click **Connect**. Every printer Bambuddy has appears, and the menu bar starts showing progress straight away.

The API key is stored in your keychain and only ever sent to your Bambuddy server. **Printers** in the window shows the server, lets you change the address or key, and disconnects.

Closing the window keeps Bambu Bar running in the menu bar without a Dock icon. Opened at login, it starts quietly in the menu bar; open it from Spotlight or the menu bar to see the window.

### About downloaded builds

Direct distribution builds are **universal, Developer ID signed and notarized by Apple**, so they open normally after you download them. Builds you make yourself without a Developer ID certificate, and the artifacts of the [Actions](https://github.com/rolottr/bambu-bar/actions/workflows/build.yml) workflow, are ad-hoc signed: they run on the Mac that built them, but the desktop widget only loads in a Developer ID signed copy.

### Controlling prints

Commands go through Bambuddy, so the API key needs **Control printer** turned on; without it Bambu Bar says so. Pause, resume, stop and speed changes are also accepted only when the printer is in **LAN Only** mode with **Developer Mode** on (printer screen → Settings → Network). That's Bambu Lab's rule for third-party apps; without it the buttons show a lock.

## Desktop widgets

<p align="center">
  <img src=".github/assets/widgets.webp" width="480" alt="The Bambu Bar widget morphing from small to medium to large while a print plays through printing, paused and finished">
</p>

- **Small:** a progress ring with the percentage, time left, the filament going in, and the finish time and layers. Paused, it says why; finished, how long ago and how long it took; idle, the temperatures and loaded spools.
- **Medium:** the rendered printer with the part growing in the filament's colour and the AMS spools in theirs, the job and its progress, finish time, layers and temperatures.
- **Large:** everything: temperature tiles (the chamber where the model has a sensor, otherwise the second nozzle or the part fan), every AMS spool with what's left on it, the newest error in plain words and how the last print went.

To add one, right-click the desktop and choose **Edit Widgets…**, search for **Bambu Bar** and drag the size you want onto the desktop or into Notification Center. With more than one printer, right-click a widget and choose **Edit "Printer"** to pick which printer it shows; a widget left empty follows the menu bar printer.

The widget shows what the app last saw, so keep Bambu Bar running (Open at Login does that). While a print runs, the widget projects progress and time left forward on its own between updates.

## Compatibility

| Printer | Status |
| --- | --- |
| **P2S** | Development printer; verified with firmware **01.03.00.00** and an AMS 2 Pro. |
| **X1, P1, A1, H2 families** | Same LAN protocol and certificate authorities; implemented, not verified on hardware. |

Any printer Bambuddy supports should work, since Bambu Bar only sees what Bambuddy reports. Controls need LAN Only with Developer Mode (see above). The camera is not shown.

## How it works

Bambu Bar talks only to your Bambuddy server's API (`/api/v1`), authenticated with the `X-API-Key` header. It lists the printers with `GET /printers/` every minute, fetches each one's full status from `GET /printers/{id}/status`, and opens one WebSocket (`/api/v1/ws`, with a short-lived token from `POST /auth/ws-token`) on which Bambuddy pushes status changes as they happen. Pushes carry only some fields, so they're merged over the last full status, and each printer is also polled every 30 seconds (10 while the WebSocket is down) for what Bambuddy doesn't push, such as time left and errors. Commands are `POST`s to `print/pause`, `print/resume`, `print/stop`, `print-speed` and `chamber-light`.

The widgets read a snapshot the app writes to an app group container on this Mac.

## Privacy and local storage

Bambu Bar talks only to your Bambuddy server, with no app analytics. Optional supporter licenses are validated online to enable automatic updates and the Hero Supporter badge. Both manual and automatic in-app update checks require an active website supporter license. License checks send the key, activation ID and a random installation ID, never printer data. Supporter benefits remain active for up to seven days offline after validation; printer monitoring has no license or offline-time limit. The Mac App Store build uses Apple’s distribution. See the [privacy policy](PRIVACY.md).

- **Bambuddy server address, its printers (name, serial, model, Bambuddy id) and preferences:** local macOS user defaults.
- **API key:** your login keychain.
- **Last prints** (for "Last: …" and finish times, only what the app saw while running): `~/Library/Application Support/Bambu Bar/history.json`.
- **Widget snapshot:** `~/Library/Group Containers/<team>.dev.rolottr.BambuBar/printers.json`.

The App Store version is sandboxed, so its settings and history live in `~/Library/Containers/dev.rolottr.BambuBar` instead.

## Building from source

Requirements: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The direct build uses Sparkle for signed updates.

```sh
git clone https://github.com/rolottr/bambu-bar.git
cd bambu-bar
./scripts/build.sh               # build/App.noindex/Bambu Bar.app (universal, release)
./scripts/install.sh             # copy to /Applications and open it
./scripts/install.sh --build     # rebuild first
```

`build.sh` generates the Xcode project from `project.yml`, builds the app and its widget extension, and signs both with the first **Developer ID Application** identity in your keychain (override with `SIGN_IDENTITY=…`; set `TEAM_ID` to match its team, which names the app group the widget shares). Without one the app is signed ad hoc and works without the widget. `CONFIG=Debug` and `ARCHS=arm64` are available. Builds go into a `.noindex` folder so Spotlight and Launchpad only ever find the installed copy.

### Package and notarize a release

```sh
NOTARY_PROFILE=<profile> ./scripts/package.sh
```

This makes a universal release build signed with Developer ID, the Hardened Runtime and a secure timestamp, submits it to Apple's notary service, staples the ticket and checks it with Gatekeeper, then writes `build/Bambu-Bar-<version>-macos.zip` and its SHA-256 checksum. The profile is a [notarytool keychain profile](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) (`xcrun notarytool store-credentials`). Without `NOTARY_PROFILE` it packages the signed build without notarizing.

To verify a download, run this next to both files:

```sh
shasum -a 256 -c Bambu-Bar-1.0.0-macos.zip.sha256
```

### Publish an update

In-app updates use [Sparkle](https://sparkle-project.org). After `gh release create v<version>` with the notarized zip, run:

```sh
UPLOAD=1 ./scripts/appcast.sh
```

It signs the zip with the EdDSA key in the login keychain (`SUPublicEDKey` in `Resources/Sparkle-Info.plist` is its public half; build.sh adds that file to the GitHub build only), turns the release's text into the release notes shown in the update window, and attaches `appcast.xml` to the release. The app checks GitHub’s latest release metadata first, then reads `releases/latest/download/appcast.xml` when a newer version is available. Both checks require an active website supporter license. The newest release must include the ZIP and its matching signed appcast. Back the key up with Sparkle's `generate_keys -x <file>` (in `build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin`): without it, installed copies can't be updated.

The [GitHub Actions workflow](.github/workflows/build.yml) builds and uploads an ad-hoc signed ZIP on pushes and pull requests. It does not sign, notarize or publish a release.

### Mac App Store build

```sh
./scripts/appstore.sh             # archive + export build/AppStore/Export/Bambu Bar.pkg
UPLOAD=1 ./scripts/appstore.sh    # archive + upload to App Store Connect
./scripts/appstore-media.sh       # 2880×1800 screenshots + 1080p app preview, drawn from the demo printers
```

The **AppStore** configuration (scheme **BambuBar App Store**, also for Product → Archive in Xcode after `scripts/generate.sh`) builds a sandboxed app with Xcode's automatic signing and leaves out the GitHub update checker.

### Developing without a printer

- `--demo [printing|preparing|paused|finished|failed|idle|offline|unconfigured]` runs a simulated P2S; add `--fleet` for six printers. Nothing is saved and no network is used.
- `scripts/showcase.sh <dir>` screenshots the panel, window and widgets in each demo state; `scripts/make-readme-animations.sh` renders the animations above, offscreen, from the demo printer.
- `scripts/make-hms.py` regenerates the bundled error texts.
- `scripts/make-filaments.py Resources/filaments.json` regenerates the filament presets and Bambu Lab colour names from Bambu Studio.
- `artwork/generate_printers.py` builds the printer models in Blender and writes the 3D models (`Resources/Printers/*.usdz`) and the widget render layers. Run it headless with `Blender -b --factory-startup -P artwork/generate_printers.py` (add shape names such as `enclosed mini` to build only those), or from a running Blender through its MCP add-on.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘1` – `⌘5` | Printer, Filament, Widgets, Settings, About. |
| `⌘R` | Ask the printer for a full report, through Bambuddy. |
| `⌘L` | Turn the chamber light on or off. |
| `⌘,` | Settings. |

The **Printer** menu also switches printers, adds one, and pauses, resumes or stops the print.

## Credits and license

Created by [NINA LABS, LLC](https://www.ninalabs.ai). Released under the [MIT License](LICENSE).

Protocol details, a real P2S report and Bambu Lab's HMS error texts in 14 languages come from [ha-bambulab](https://github.com/greghesp/ha-bambulab) (MIT), which also provided Bambu Lab's certificate authorities that ship with the app. [Bambuddy](https://github.com/maziggy/bambuddy) and [bambu-cli](https://github.com/tobiasbischoff/bambu-cli) helped map the newer printers, and the access-code import follows [Bambu Studio](https://github.com/bambulab/BambuStudio)'s settings format. Each model's capabilities and build volume follow the printer profiles in Bambu Studio's `resources/printers` and `resources/profiles/BBL/machine`, and filament makers and colour names come from its `resources/profiles/BBL/filament`. In-app updates use [Sparkle](https://sparkle-project.org) (MIT).

The printer models were built for this project in Blender from published outer dimensions; they are visual approximations, not manufacturer CAD, and carry no logos. The generator is in `artwork/`.

Bambu Lab, Bambu Studio, Bambu Handy, AMS and P2S are trademarks of Bambu Lab. This project is not affiliated with Bambu Lab.
