# Architecture

## Overview

```
┌──────────────────────────── Arrow.app (browser process) ───────────────────────────┐
│ SwiftUI views (Sidebar, ContentPanel, CommandBar, Library, Settings…)              │
│        │ observe                                                                   │
│ BrowserStore ── BrowserState (ArrowKit) ── JSONStore ─▶ ~/Library/…/Arrow/State    │
│   │  WebTab (one per live tab) ── CEFBrowserDelegate                               │
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

CEF publishes a stable C API (`include/capi`). `Sources/CEF/module.modulemap`
exposes it to Swift as the `CEF` module and pins `CEF_API_VERSION` so struct
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

`ArrowCore`, a second library of the same package, receives the app state
that every platform shares, as phase 3 of the [portability plan](PORTABILITY.md)
moves it out of the app. It holds `CommandBarModel` so far.

The app adds the runtime:

- **`BrowserStore`** owns the state, persistence, the Chromium profiles and
  the live `WebTab`s. It also runs maintenance every minute: auto-archive, and
  discarding background tabs after an hour.
- **`WebTab`** mirrors a page's state for SwiftUI and implements
  `CEFBrowserDelegate`: popups, Peek, context menus, permissions, media
  detection, Boost injection.
- **`WindowState`** and **`BrowserWindowController`** handle the selection,
  the overlays and every menu command.

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
