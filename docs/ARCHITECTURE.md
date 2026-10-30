# Architecture

## Overview

```
┌──────────────────────────── Arrow.app (browser process) ───────────────────────────┐
│ SwiftUI views (Sidebar, ContentPanel, CommandBar, Library, Settings…)              │
│        │ observe                                                                   │
│ BrowserStore (ArrowCore) ── BrowserState (ArrowKit) ── JSONStore ─▶ …/State        │
│   │  WebTab (ArrowCore, one per live tab) ── BrowserEngine protocols               │
│   │        │                                                                       │
│   │  CEFBrowser ── cef_client_t + handlers implemented in Swift (CefHandler<T>)   │
│   │        │ C API                                                                 │
│   └─ CEFRuntime ── cef_initialize / cef_run_message_loop                           │
│                     Chromium Embedded Framework.framework                          │
└──────────────┬─────────────────────────────────────────────────────────────────────┘
               │ Mojo IPC
   Arrow Helper (Renderer | GPU | Plugin | Alerts).app  ← Sources/ArrowHelper (Swift)
```

## Chromium integration without C++

CEF publishes a stable C API (`include/capi`). The `CEF` module of
`Packages/ArrowCEF` exposes it to Swift and pins `CEF_API_VERSION` so struct
layouts match the version given to `cef_api_hash()` at startup.

- **Reference counting** (`CEFRefCounting.swift`). CEF objects implemented by
  Swift (`cef_client_t`, handlers, callbacks) are allocated by
  `CefHandler<T>`: the C struct is followed by a trailer pointing to a Swift
  box with an atomic reference count and a weak link to the Swift owner.
  Callbacks recover their owner from `self`. Objects owned by CEF are wrapped
  in `CefRef<T>`. The rules follow `libcef_dll/cpptoc` and `ctocpp` in the
  distribution:
  - callback arguments carry a reference that is released;
  - returned structs are adopted;
  - arguments passed to CEF transfer a reference.
- **Threads**. The CEF UI thread is the main thread on macOS, so
  callbacks hop into `MainActor.assumeIsolated`.
- **Application**. `ArrowApplication` implements `CrAppProtocol`,
  `CrAppControlProtocol` and `CefAppProtocol`; `cef_run_message_loop()` drives
  `NSApplication`. `terminate:` closes every browser first, then quits the loop
  and calls `cef_shutdown()`.
- **Helpers**. Each helper app enters the macOS sandbox
  (`libcef_sandbox.dylib`) and only then loads the framework with `dlopen`, the
  same order as CEF's C++ `CefScopedSandboxContext` and
  `CefScopedLibraryLoader`.
- **Framework embedding**. CEF ships an unversioned framework that Xcode
  refuses to embed, so a build phase installs it with the standard
  `Versions/A` layout (like Chromium's own framework) and signs it.

## Browsers in SwiftUI

Each tab is a `CEFBrowser` whose Chromium view lives in a `CEFHostView`.
Chromium uses Alloy style, the only style allowed when a browser has a native
parent view. `WebContentView` (an `NSViewRepresentable`) attaches the host view
of the displayed tab.

Chromium needs its view to be in a window both when the browser is created and
while it keeps working in the background. Views that are not displayed are
therefore moved to `CEFParkingLot`, an invisible window: background tabs keep
loading and switching tabs never orphans a browser.

Closing a tab calls `close_browser`. `do_close` returns 1, because the parent
is our own window and CEF must not close it; then the host view is torn down
and `on_before_close` completes the close.

## Model

`Packages/ArrowKit` holds everything that does not depend on the engine, so it
can be unit tested with `swift test`, on macOS, Linux and Windows (see
[Portability](PORTABILITY.md)):

- **`BrowserState`**: profiles, spaces (pinned and today trees of
  `SidebarNode`: tab, folder or split view), favorites per profile and the
  archive. It also implements pinning, moves, auto-archive, splits, folders
  and spaces.
- **`SpaceTheme` / `ThemePalette`**: the gradient themes and their colors,
  calibrated against Arc.
- **`URLInput` and `SearchEngine`**: what the command bar does with typed
  text; `SiteSearch` covers per-site search.
- **`CommandBarRanker`**: the command bar rows (tabs, history, suggestions,
  commands).
- **`History`, `Boost`, `ArrowSettings` (including Air Traffic Control),
  `Note`, `Easel`**.

`ArrowCore`, a second library of the same package, holds the state and
services that every platform shares, on top of ArrowKit and tested the same
way, with a fake engine and platform:

- **`BrowserStore`** owns the state, persistence, the profiles and the live
  `WebTab`s. It also runs maintenance every minute: auto-archive, and
  discarding background tabs after an hour. It receives the engine and the
  platform services (see below).
- **`WebTab`** mirrors a page's state for the UI and implements
  `BrowserEngineDelegate`: popups, Peek, context menus, permissions, media
  detection, Boost injection, Autofill.
- **`WindowState`** and **`CommandBarModel`**: the selection, the overlays
  and the command bar of a window.
- **Services**: `DownloadManager`, `ExtensionManager`, `AdBlocker`,
  `ArrowCloud`, `CastController`, `AIFeatures`, `FaviconCache`. Favicons and
  page snapshots are PNG data (`PageImage`) that each app decodes.

The macOS app adds the SwiftUI and AppKit views, `BrowserWindowController`
(the window and every menu command) and `MacPlatform`, and uses the CEF
bindings of `Packages/ArrowCEF`.

## Engine boundary

The model reaches Chromium only through engine protocols, so it can be
shared by every platform. They live in `ArrowEngine`, a library of the
ArrowKit package with no dependency, so the engine bindings build without the
model; `ArrowCore` re-exports it.

- **`BrowserEngine`**: one browser (navigation, scripts, DevTools methods,
  find, zoom, screenshots as PNG data). Its events go to a
  `BrowserEngineDelegate`, with engine-neutral types (`PopupFeatures`,
  `ContextMenuParams`, `PermissionRequest`…).
- **`BrowsingContext`**: a profile, which creates browsers and media routers
  and clears cookies and cache.
- **`EngineRuntime`**: the profiles, the `DownloadCenter` and the
  `ResourceFilter` (ad blocker) shared by every browser.

`ArrowCEF` (`Packages/ArrowCEF`) implements them with `CEFBrowser`,
`CEFRequestContext` and `CEFRuntime`. macOS code that needs CEF itself (the
`NSView` hosting a browser, sized popups, site settings) casts to the CEF
types.

## Platform services

What the model needs from the operating system goes through ArrowCore's
`Platform` protocol: saved logins and cards (`CredentialStore`), Arrow
Cloud's secrets (`SecretStore`), the clipboard, sounds, held keyboard
modifiers, the system appearance, revealing and opening files, unzipping, and
the settings applied by the app (global shortcut, menu shortcuts).
`MacPlatform` implements it with AppKit, the Keychain (`Keychain.swift`) and
Carbon. `BrowserStore` receives it with the engine.

## Profiles and incognito

Each profile is a Chromium request context with its own cache directory
(`Default/` for the default profile, `Profiles/<id>/` for the others).
Incognito windows use an ephemeral `BrowserStore` with an in-memory request
context; nothing is written to disk.

## Extensions

Embedded (Alloy) browsers cannot show Chrome's extension UI, but the Chrome
runtime runs a profile's extensions for every browser in it.

`ExtensionManager` installs an extension in four steps:

1. Download the CRX from the Chrome Web Store.
2. Verify the CRX3 RSA signature and check that the publisher key matches the
   extension ID (`CRXPackage`).
3. Unpack it, adding the publisher `key` to the manifest so the extension keeps
   its Web Store ID.
4. Load the enabled extensions when Chromium starts (`--load-extension`).

Action popups open in an auto-sized `NSPopover`. Extension APIs that need tab
objects (`chrome.tabs`) do not see Alloy browsers.

## Arrow Cloud

`ArrowCloud` talks to `server/`:

- **Accounts**: bearer tokens kept in the Keychain.
- **Sync**: each space, the favorites and the layout are encrypted with
  AES-GCM using a key that never leaves the Keychain, pushed with optimistic
  concurrency and pulled when the server sends an SSE revision event.
- **Sharing, AI tasks and feedback**.
