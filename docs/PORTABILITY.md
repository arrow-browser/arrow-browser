# Portability: Windows and Linux

Decided on 2026-10-30. Arrow only runs on macOS today. This document records
the decision to bring it to Windows and Linux, and the plan to get there.

## Decision

- **Arrow will ship on Windows and Linux.** macOS stays the reference
  platform.
- **Chromium (CEF) on every platform.** CEF ships for Windows and Linux with
  the same C API, so the engine, web compatibility and Chrome extensions are
  the same everywhere.
- **A shared Swift core and a native UI per platform.** Swift has official
  toolchains for Windows and Linux. The UI stays native: SwiftUI and AppKit on
  macOS, and WinUI 3 through
  [swift-winrt](https://github.com/thebrowsercompany/swift-winrt) on Windows,
  the approach The Browser Company used for Arc on Windows. The Linux toolkit
  is still open (see [Open questions](#open-questions)).
- **One engine.** Supporting WebKit or Gecko next to Chromium is dropped for
  now:
  - Gecko has no desktop embedding API (GeckoView is Android only). Using it
    would mean building and maintaining a "CEF for Gecko".
  - WebKit (`WKWebView`) would mean rebuilding what Arrow gets from Chromium:
    Chrome extensions, request-level ad blocking, Cast, the embedded DevTools,
    per-tab processes in the task manager.
  - Every feature would be built and tested once per engine, and cookies and
    logins are not shared between engines.

  The engine boundary drawn in phase 3 would make a second engine possible
  later, if a concrete need shows up.

## Starting point

At `e4de7af`, Arrow is about 19,600 lines of Swift:

| Part | Lines | Portable |
|---|---|---|
| `Packages/ArrowKit`: model, persistence, parsers | ~3,000 | Yes since phase 1: builds and passes its tests on Linux. |
| `Sources/Arrow/CEF`: CEF bindings | ~1,900 | Mostly. macOS-specific: hosting browsers in `NSView`s, the helper sandbox, the helper app bundles. |
| `Sources/Arrow/Model`, `Services` | ~4,000 | Partly. 16 files import AppKit or SwiftUI, mixing logic with macOS code. |
| `Sources/Arrow/Views`, `App`, `Theme` | ~10,400 | No. SwiftUI and AppKit, rebuilt per platform. |

## Plan

### Phase 1: portable ArrowKit (done)

- CryptoKit is replaced by [swift-crypto](https://github.com/apple/swift-crypto).
  `Crypto` is CryptoKit itself on Apple platforms.
- The CRX3 signature check moves from Security and a hand-written ASN.1 parser
  to RSA in `CryptoExtras`: the same code on every platform.
- CI runs `swift test` for ArrowKit on Linux
  (`.github/workflows/portability.yml`).

### Phase 2: ArrowKit on Windows

- Add a Windows job to the portability workflow and fix what Foundation does
  differently there (paths, file APIs).

Done when `swift test` passes on Windows in CI.

### Phase 3: shared core

- Move the platform-independent part of `Model/` and `Services/` (browser
  store, tabs, downloads, extensions, ad blocker, sync, Cast) into a SwiftPM
  package, `ArrowCore`, that imports neither AppKit nor SwiftUI. Observation
  ships with the Swift toolchain, so `@Observable` models can move as they are
  (checked on Linux; Windows in phase 2).
- Put platform services behind protocols implemented by each app (see
  [Platform services](#platform-services)).
- Draw the engine boundary: the model and the views talk to a browser
  protocol, which `CEFBrowser` implements.
- The macOS app builds on `ArrowCore`, with no change in behavior.

Done when `ArrowCore` is tested on Linux and Windows in CI and the macOS app
uses it.

### Phase 4: portable CEF bindings

- Host browsers in the native window handle of each platform: `NSView`,
  `HWND`, X11 or Wayland window.
- Process model: Windows and Linux have no helper app bundles. Subprocesses
  relaunch the main executable or a single helper executable
  (`browser_subprocess_path`).
- Sandbox: `cef_sandbox` on Windows (a static library linked into the
  executable), Chromium's sandbox on Linux.
- `scripts/fetch-cef.sh` fetches the Windows and Linux distributions (x64 and
  arm64).

Done when a window with one CEF browser runs on Windows and Linux.

### Phase 5: Windows app

- WinUI 3 through swift-winrt. The Browser Company archived its prebuilt
  binding packages (`swift-winui`, `swift-windowsappsdk`) and recommends
  generating your own projections with swift-winrt: Arrow generates and
  versions the subset of WinUI and the Windows App SDK it uses.
- Rebuild the UI of the macOS app: sidebar, spaces, command bar, split view,
  Peek, Library, settings.
- Build with SwiftPM (CMake where SwiftPM falls short), ship an installer.
- Updates reuse ArrowKit's appcast parser and EdDSA check; only the install
  step is Windows-specific.

### Phase 6: Linux app

- Pick the toolkit and rebuild the UI.
- Package as Flatpak and AppImage or distribution packages. Inside Flatpak,
  Chromium's sandbox needs [zypak](https://github.com/refi64/zypak), as for
  Electron apps and other prebuilt Chromium binaries.
- Updates come from the packaging system, not from the app.

## Platform services

What each app implements behind the protocols of phase 3:

| Service | macOS today | Windows | Linux |
|---|---|---|---|
| Saved logins, sync keys (`Autofill`, `ArrowCloud`) | Keychain | Credential Manager, DPAPI | Secret Service (libsecret) |
| Unlocking saved logins (`LocalAuthentication`) | Touch ID, account password | Windows Hello | To define |
| Global shortcut (`GlobalShortcut`) | Carbon hot keys | `RegisterHotKey` | GlobalShortcuts portal, X11 grab |
| Scripting (`AppleScriptSupport`) | AppleScript | None | D-Bus, if needed |
| Dock tile (`DockTilePlugIn`) | Dock plug-in | Taskbar jump list and overlay | None |
| File thumbnails (`MediaLibrary`) | QuickLook | Shell thumbnail API | None |
| Updates (`Updater`) | Appcast, EdDSA | Same appcast, Windows installer | Packaging system |
| Import from other browsers (`BrowserImporter`) | Profiles under `~/Library` | Profiles under `%LOCALAPPDATA%` | Profiles under `~/.config` |

## Rules while porting

- ArrowKit, and later `ArrowCore`, import no Apple-only framework: no AppKit,
  SwiftUI, Security or CryptoKit. Cryptography goes through `Crypto` and
  `CryptoExtras`. The Linux CI job catches regressions.
- Anything platform-specific goes behind a protocol implemented by the app.
- Moving code to the shared core does not change how the macOS app behaves.

## Open questions

- **Linux toolkit.** GTK 4 with libadwaita is the most likely candidate, but
  its Swift bindings are less mature than swift-winrt.
- **Order of the Windows and Linux apps.** Windows first is proposed: larger
  audience, and the swift-winrt path is proven by Arc.
- **Wayland.** How well CEF's windowed mode works under Wayland, to check in
  phase 4.
