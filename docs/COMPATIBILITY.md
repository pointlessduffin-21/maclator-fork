# Compatibility list

What was tried under Maclator, and how it went. Generated from [compatibility.json](compatibility.json) by `scripts/compat.py markdown`; the launcher app reads the same file.

- **Works**: the app starts and opens its window; anything beyond that is in the notes.
- **Partly works**: it starts, but something breaks or is missing (see the notes).
- **Doesn't run**: it never reaches a usable window.
- **Not tried**: no result recorded.

Times are to the first window on a first launch with an empty translation cache; later launches are faster.

Tested on: Intel Core i5-10310U (4 cores / 8 threads), Intel UHD Graphics, macOS 26.6.

To add your own results, run apps from Maclator.app (it records each run on your Mac), then `scripts/compat.py import && scripts/compat.py markdown`.

## Works (21)

| App | Bundle ID | First window | Tested | Notes |
|---|---|---|---|---|
| AppCleaner | `net.freemacsoft.AppCleaner` | 40 s | 2026-10-02 | Objective-C/AppKit. Window after about 40 s on the first launch. |
| ChatGPT | `com.openai.codex` | 102 s | 2026-10-11 | Chromium-based, arm64 only (no Intel version). Needs --no-sandbox; window after about 2 minutes on the first launch. |
| coconutBattery | `com.coconut-flavour.coconutBattery` | 26 s | 2026-10-02 | Swift/AppKit. Battery readings not checked. |
| Final Cut Pro | `com.apple.FinalCutApp` | 87 s | 2026-10-02 | Sandboxed. Editing and rendering not checked. |
| FluxMarkdown | `com.xykong.Markdown` | 8 s | 2026-10-02 | Swift. |
| foobar2000 | `com.foobar2000.mac` | 15 s | 2026-10-02 | C++/AppKit. |
| Google Chrome | `com.google.Chrome` | 29 s | 2026-10-02 | Chromium 154. Needs --no-sandbox. |
| HandBrake | `fr.handbrake.HandBrake` | 36 s | 2026-10-02 | Sandboxed, but starts. Encoding not checked. |
| Hidden Bar | `com.dwarvesv.minimalbar` | 8 s | 2026-10-02 | Swift, sandboxed, from the App Store. |
| Keynote | `com.apple.Keynote` | 20 s | 2026-10-02 | As Pages. |
| Microsoft Excel | `com.microsoft.Excel` | 15 s | 2026-10-02 | Sandboxed. |
| Microsoft OneNote | `com.microsoft.onenote.mac` | 19 s | 2026-10-02 | Needed thread_suspend/get_state for JavaScriptCore's GC (now emulated). |
| Microsoft PowerPoint | `com.microsoft.Powerpoint` | 21 s | 2026-10-02 | Sandboxed. |
| Microsoft Word | `com.microsoft.Word` | 26 s | 2026-10-02 | Sandboxed. Documents not checked. |
| Mos | `com.caldis.Mos` | 12 s | 2026-10-02 | Swift. Scroll smoothing itself not checked (needs the Accessibility permission). |
| Numbers | `com.apple.Numbers` | 16 s | 2026-10-02 | As Pages. |
| Pages | `com.apple.Pages` | 15 s | 2026-10-02 | Needed the guest's own entitlements (CloudKit traps without them). High CPU at idle; iCloud not checked. |
| Pixelmator Pro | `com.pixelmatorteam.pixelmator.x` |  | 2026-10-02 | Relaunches itself on start; the second copy opens the window. |
| Termius | `com.termius-dmg.mac` | 145 s | 2026-10-02 | Electron. Window after about 2.5 minutes on the first launch. |
| VLC | `org.videolan.vlc` | 10 s | 2026-10-02 | Playback not checked. |
| Windows App | `com.microsoft.rdc.macos` | 11 s | 2026-10-02 | Sandboxed. Remote sessions not checked. |

## Partly works (4)

| App | Bundle ID | First window | Tested | Notes |
|---|---|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | 8 s | 2026-10-02 | Opens a window and runs its event loop; whether the terminal draws is unconfirmed (it renders through CAMetalLayer, which the GPU bridge doesn't cover yet). |
| OneDrive | `com.microsoft.OneDrive` |  | 2026-10-02 | Menu-bar app: starts and keeps running; no window to check. |
| Pixelmator Pro Creator Studio | `com.apple.pixelmator` | 44 s | 2026-10-11 | Opened a window, then quit with an error. |
| RDM | `net.alkalay.RDM` |  | 2026-10-02 | Menu-bar app: starts and stays running; the menu itself not checked yet. |
