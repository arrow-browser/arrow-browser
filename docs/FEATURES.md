# Feature parity with Arc

Status: ✅ done · 🟡 partial · ❌ not yet.

Menus and keyboard shortcuts were extracted from Arc 1.170's `MainMenu.nib`
and are reproduced in `Sources/Arrow/App/MainMenu.swift`.

## Window and look

| Feature | Status | Notes |
|---|---|---|
| Sidebar with traffic lights, sidebar toggle, back/forward/reload | ✅ | Geometry measured on Arc (traffic lights centered 23.5 pt from the top, content inset 9 pt). |
| Space gradient themes with grain, light / dark / automatic | ✅ | Palette derived like Arc's `windowTheme` (`ThemePalette`). Spaces ▸ Edit Theme… is Arc's compact picker (dotted canvas, light/dark, swatches, grain wave, intensity dial), compared with Arc at the pixel. Arc's default theme is translucent and changes with the screen behind it; Arrow draws one measured rendering of it. |
| Rounded content panel, behind-window vibrancy | ✅ | |
| Hide sidebar (⌘S) and reveal on hover at the window edge | ✅ | |
| Sidebar on the right, resizable sidebar | ✅ | |
| Toolbar mode (Arc's hidden "Show/Hide Toolbar", ⇧⌘D) | ✅ | Horizontal toolbar with the URL field above the page, sidebar hidden. |
| Menu bar | ✅ | Same items, order and shortcuts as Arc 1.170's menus as macOS shows them (compared item by item through the accessibility API): spaces listed with ⌃1–9, installed extensions, Appearance, Collapse Pinned Tabs, Expand Current Split, Reveal Tab in Sidebar, Stay On Top, Capture in Portrait Mode, Network Inspector, Record Trace, Task Manager, Restore Data, Export Notes… System items follow the user's language. |
| Preferences (⌘,) | ✅ | Arc's window and eight panes: account card, General, Profiles, Max, Links, Shortcuts (custom shortcuts), Icon, Advanced. Arrow-only settings are under Advanced ▸ More Settings…. |

## Tabs and sidebar

| Feature | Status | Notes |
|---|---|---|
| Favorites grid (per profile) | ✅ | |
| Pinned tabs: pinned URL, "Back to Pinned URL", unload | ✅ | |
| Today tabs (newest first), "+ New Tab" row, "Clear" | ✅ | |
| Folders: create, rename, collapse, nest | ✅ | |
| Drag and drop between favorites, pinned, today and folders | ✅ | Checked with real mouse input (a Today tab dragged into favorites). |
| Split View: 2–4 panes, side by side or stacked (⌃⇧=, ⌃⇧-) | ✅ | Also by dragging a sidebar tab onto the content. |
| Auto-archive after 12 h / 24 h / 7 d / 30 d | ✅ | |
| Archive, restore last closed tab (⇧⌘T) | ✅ | |
| Rename, duplicate, mute, audio and camera/mic indicators | ✅ | |
| ⌘1–9, ⌥⌘↑/↓, ⌃Tab | ✅ | ⌃Tab shows the recent-tabs switcher; releasing ⌃ opens the highlighted tab. |
| Background tab memory saver | ✅ | Tabs hidden for an hour are unloaded. |
| Tab hover previews | ✅ | Hovering a favorite shows the page's snapshot, title and address (can be turned off in Settings ▸ Advanced). |

## Command bar

| Feature | Status | Notes |
|---|---|---|
| ⌘T new tab, ⌘L edit the current URL | ✅ | |
| Search suggestions, open tabs ("Switch to Tab"), history, commands | ✅ | |
| Site search (type a site name, then Tab) | ✅ | 20 built-in sites. |
| Choice of search engine | ✅ | 9 engines. |
| Look and position | ✅ | Measured on Arc at two window sizes: centered panel, 62 pt field, 46 pt rows, default-browser footer ("Try for a week" trial, then "How are you liking Arrow?"). |
| Inline autocompletion | ✅ | Typing completes the address from history, completion selected; Delete removes it. |
| Instant Links (Max) | ✅ | Shift-Return opens the top result (Google "I'm Feeling Lucky", DuckDuckGo `\` for other engines). |
| ChatGPT in the Command Bar (Max) | ✅ | "chatgpt" + Tab, and an "Ask ChatGPT" suggestion. |

## Spaces, profiles, windows

| Feature | Status | Notes |
|---|---|---|
| Create, edit, reorder and delete spaces; icons and themes | ✅ | |
| Switch spaces: swipe, ⌃1–9, ⌥⌘←/→, bottom bar | ✅ | Two-finger swipe checked with real scroll events. |
| Profiles: separate cookies and storage per space | ✅ | |
| Incognito windows | ✅ | In-memory profile, nothing persisted. |
| Little Arc → Little Arrow, "Open in <space>" | ✅ | ⌥⌘N opens Arc's compact command bar (490 pt wide, top right), which grows into the page window (1185×832) with the address field and "Open in <space> ⌘O ⌄". Compared with Little Arc at the pixel; Arc's extensions icon in the field is not drawn. |
| Links from other apps, Air Traffic Control rules | ✅ | |
| Peek: links from pinned tabs and favorites to other sites | ✅ | Arc's layout, compared at the pixel: a card over the page veiled in the space colors, with close, open as tab and add to split view beside it. |
| Window and selection restored at launch | ✅ | |

## Web content

| Feature | Status | Notes |
|---|---|---|
| Context menus: link, image, selection, page, Inspect | ✅ | |
| Find in page | ✅ | |
| Zoom, print, save page as PDF | ✅ | Arc saves HTML; Arrow saves PDF. |
| Downloads: progress, pause, resume, cancel, reveal | ✅ | Like Chrome, a new tab opened only for a download closes when the download ends. |
| Permission prompts: camera, microphone, location, notifications… | ✅ | |
| Site controls: zoom, permissions (camera, mic, location, notifications, pop-ups, sound), ad blocker, boosts, Zap, clear cookies and cache | ✅ | |
| Automatic Picture in Picture | ✅ | A video playing with sound opens in Picture in Picture when you switch tabs, and returns to the page when you come back (checked with a playing video). Like Arc, pages that disable Picture in Picture are skipped. |
| Media controls in the sidebar | ✅ | |
| Developer tools, view source, inspect, console, developer mode | ✅ | |
| Error and crash pages | ✅ | |

## Arc tools

| Feature | Status | Notes |
|---|---|---|
| Boosts: colors, fonts, hidden elements, custom CSS and JavaScript | ✅ | Live preview; Zap hides clicked elements and saves them to the site's boost. |
| Notes | ✅ | Rich text, opened as a tab. |
| Easels | ✅ | Text, pasted images, tab captures; pen, highlighter and eraser with a color palette. |
| Capture (⇧⌘2) | ✅ | Drag to select an area, or capture the full page; copied to the clipboard. |
| Library: Media, Downloads, Easels, Spaces, Boosts, Archived Tabs | ✅ | In place of the sidebar, as in Arc: a rail of sections, a searchable list grouped by day (Filter by space or file kind) and the page on the right; Spaces shows a card per space. Compared with Arc at the pixel. History opens from ⌘Y. Arc draws the cards of custom themes more saturated than Arrow. |
| Copy URL, as Markdown, as quote; Share | ✅ | |
| Tidy Tabs (Max) | ✅ | ✦ next to the Today divider (more than six Today tabs) sorts them by topic through Arrow Cloud's AI. |
| Shared Quotes | ✅ | A "Copy Quote" button over highlighted text copies the quote with a link to the highlight (text fragment). |

## Platform

| Feature | Status | Notes |
|---|---|---|
| Chrome extensions from the Chrome Web Store | ✅ | Signature-verified install, action popups. `chrome.tabs` cannot see Arrow tabs. Changes need a relaunch. |
| Built-in ad blocker | ✅ | EasyList + EasyPrivacy host rules (~90k), from Arrow Cloud or easylist.to; can be turned off per site in Site Controls. |
| Import from Arc (spaces, themes, pinned tabs, folders, favorites) | ✅ | |
| Import from Chrome, Brave, Edge, Vivaldi, Safari | ✅ | Bookmarks become pinned folders. Safari needs Full Disk Access. |
| Default browser | ✅ | |
| Sync across Macs | ✅ | End-to-end encrypted, through `server/`. |
| Sharing | ✅ | "Share Space…" / "Share Folder…" publish a page on Arrow Cloud; `arrowBrowser://share/<id>` links import it as a folder. |
| AI features (tidy tab titles, tidy downloads, previews, ask on page) | ✅ | Through Arrow Cloud (Claude): titles tidied when pinning, downloads renamed, ✨ in the find bar answers questions about the page, ✨ in Peek summarizes. Needs an account on a server with `ANTHROPIC_API_KEY`, or a local model through Ollama (see `server/README.md`). All four checked end to end with a local model. |
| Updates | ✅ | Sparkle-format appcast from `server/`; archives must match the Ed25519 key in `SUPublicEDKey` (`scripts/sign-update.swift`). Downloaded and verified in the background, "Restart to Update" in the sidebar. Without a key, Arrow only offers the download, so generate one before the first release (see the README). Checked end to end with a real click: 1.0.0 → 1.0.1 from a local server, replaced in place and relaunched. |
| AppleScript | ✅ | Same dictionary as Arc (windows, tabs, spaces; select, go back/forward, reload, stop, execute javascript, focus, make new tab), so Arc scripts work by targeting Arrow. |
| Translate page | ✅ | Through Google's translation proxy, from Site Controls, the View menu or the command bar. |
| View ▸ Appearance | ✅ | Light, dark or automatic `prefers-color-scheme` for web pages, easels and notes. |
| Allow websites to get your theme data | ✅ | Arc's `--arc-palette-*` CSS variables. |
| Warn before quitting | ✅ | Arc's "Quit Arrow?" dialog, with "Quit, and don't ask again". |
| ⌥⌘N from any app, ⌥⌘-click → Little Arrow, Shift-click → Peek, archive idle Little Arrows | ✅ | Preferences ▸ Links. ⌥⌘N (from the Finder) and Shift-click checked with real keyboard and mouse input. |
| Download location, search suggestions, clear browsing data | ✅ | Preferences ▸ Profiles. Cookies and cache are cleared for all time (Chromium's embedded API has no time range for them). |
| Restore Data, Export Arrow Notes, Export Data | ✅ | Restores a dated copy of the sidebar; notes as RTF files; Arrow's data as a zip. |
| Task Manager, Record Trace | ✅ | Arrow's processes with memory and CPU (End Process); Chromium traces saved as JSON. |
| Cast | 🟡 | View ▸ Cast lists the Cast devices (Chromecast, Google TV, Cast speakers) found by Chromium's Media Router (CEF C API) and plays the page's video or audio on the chosen one with Google's Default Media Receiver: play/pause, stop, and the page pauses once the device plays. CEF has no tab mirroring, so only media with a web address can be cast, not streams built by the page (`blob:` URLs, as on YouTube). Checked: page media detection, and device discovery against a simulated device advertised on this Mac only (Chromium resolves it and opens a Cast channel, which then fails authentication, as expected without Google's device certificate). Not checked: casting to a real device, since none was on the test network. Discovery runs from launch (Chromium's `DelayMediaSinkDiscovery` is turned off because it waits for a gesture in Chrome's Cast dialog, which CEF doesn't include), so macOS asks for Local Network access at first launch rather than at first use. |
| Passwords | ✅ | Offers to save a login when a form is submitted and fills it in on the next visit (several accounts: a choice over the page). Stored in the login Keychain; Preferences ▸ Profiles ▸ Passwords lists them and shows one after Touch ID or the Mac's password. |
| Credit cards | ✅ | Offers to save a card on checkout and to fill it when a card field gets focus. The security code is never saved. |
| Sound effects | ✅ | Like Arc, two sounds: a chime for events (copy, pin, archive) and a shutter for captures. Arc's sound files are not reused: `scripts/make-sounds.swift` synthesizes them from the partials, envelopes and click timings measured on Arc's (their 20 ms loudness envelopes match Arc's within a few dB). Played in the app (pin with ⌘D, capture). |
| Translation prompt | ✅ | Pages in a language the user does not read offer a translation (Never translate this language / this site); Preferences ▸ Advanced ▸ Reset Translated-site Prompts. |
| Welcome screen with Arc import, default browser prompt in the command bar | ✅ | |
| App icons and Dock tile plugin | ✅ | Six icons in Settings ▸ General; the Dock plugin keeps the chosen icon when Arrow is not running. |
