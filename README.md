# G-Clip

A native, keyboard-friendly macOS clipboard manager for personal use. **Apple Silicon (M1 or newer), macOS 13+.** Current version: **0.3.19**.

## Screenshots

### Text editing

Edit a saved text clip and save it as a new entry while preserving the original.

![G-Clip text editing with sample clipboard history](docs/screenshots/text-editing.png)

### Image editing

Add arrows, rectangles, and text annotations, with zoom and pan controls.

![G-Clip image editing with sample annotations](docs/screenshots/image-editing.png)

Screenshots use synthetic sample content from 0.3.8; the editor’s Copy button is now Save (⌘S).

## Install

1. Download `G-Clip-0.3.19-arm64.zip` from [Releases](https://github.com/costa37/g-clipboard-manager/releases).
2. Unzip it and drag **G-Clip.app** into **Applications**. Quit any older G-Clip before replacing it.
3. Open the app. This personal build is ad-hoc signed and is **not Apple-notarized**. If macOS blocks it, review the message in System Settings → Privacy & Security and use **Open Anyway** only if you trust this download. Managed Macs may prohibit it.
4. For automatic pasting, grant G-Clip access in System Settings → Privacy & Security → Accessibility. After updating, remove the existing G-Clip entry with **−**, even if its toggle is already on. Use **+** to add G-Clip from Applications again, then turn its permission on.

From 0.3.16 onward, right-click the menu-bar icon and choose **Check for Updates…**. When an update is available, a download arrow appears inside the clipboard menu-bar icon. Automatic update checks are enabled by default and can be turned off in the menu; installing an update always requires your confirmation. Users on earlier releases need to install this version manually once. Updates are verified with G-Clip’s update-signing key, then installed and relaunched by Sparkle. After updating, remove and re-add G-Clip in Accessibility—even if its toggle is already on—then enable its permission. History remains in your user Library when the app is replaced. Each Mac has independent history.

## Use

- **Option + Command + Space:** open history.
- **Up/Down**, then **Return:** select and paste plain text. **Shift + Return:** paste saved formatting while G-Clip is open.
- **Tab / Shift+Tab:** cycle All, Text, and Images while browsing.
- **Right arrow (with an empty search):** edit a clip. **Command + S** or **Save** saves a new entry and keeps the original. The saved item is also placed on the clipboard. **Command + C** copies selected text normally.
- Images support crop, movable arrows, rectangles, text annotations, zoom, and pan.
- Text editing uses unformatted text with the same readable colors as the preview, and saves edits as plain text. Original clips retain their saved formatting.
- Text editors preserve standard macOS caret movement, selection, Undo, and Redo. In a text preview, arrow keys move the text selection; focus the search box to browse clips again.
- **Escape:** leave editing or close the panel. Click outside to dismiss.
- Drag the app icon in the search box to move the window; drag the divider to resize the panes.
- Right-click the menu-bar icon for themes, font size, launch at login, updates, and Quit. **Enable Automatic Paste…** appears only while Accessibility permission is missing, both in the menu and in a clickable warning at the bottom of the main window. Clicking it expands guidance inline without blocking editing.
- `/clear` clears history; `/clear 1d` clears entries copied/reused in the last 24 hours, after confirmation. Clearing also empties the system clipboard.

The menu-bar setting **Always open on main display** is enabled by default and remembered across launches. Turn it off to open on the display under the mouse pointer. You can still drag the window after opening.

## Privacy and limitations

Clipboard history stays locally at `~/Library/Application Support/G-Clip/history.json`. There is no telemetry or cloud sync. Update checks contact GitHub to retrieve release information; downloads contact GitHub and its asset hosting service. Clipboard contents are never sent, and Sparkle system profiling is disabled. History is not encrypted by the app. Retention is 30 days / 1,000 entries, with 10 MB per clip and 100 MB total payload limits. Sensitive-clipboard filtering is best effort; pause capture before copying secrets.

This is a personal-use beta. Intel Macs are unsupported. Gemini Mini Chat automatic paste still needs end-to-end validation. Update installation and Accessibility checks on a second Mac remain necessary. Image edits export a flattened PNG; annotation layers are not saved after saving/reopening.

## Build from source

Install Xcode Command Line Tools, then run:

```sh
bash scripts/build.sh
CONFIGURATION=debug bash scripts/build.sh
dist/G-Clip.app/Contents/MacOS/GClip --self-test
bash scripts/build.sh
bash scripts/package.sh
```

The release build is at `dist/G-Clip.app`; the installable ZIP and checksum are in `dist/`. For a debug build, use `CONFIGURATION=debug bash scripts/build.sh`. No Apple developer account is required. Swift Package Manager downloads the pinned Sparkle dependency. Packaging requires the G-Clip signing key; see the release instructions.

See [release instructions](RELEASE.md) and [changelog](CHANGELOG.md). Licensed under [MIT](LICENSE).
