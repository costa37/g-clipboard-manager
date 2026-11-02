# Changelog

## 0.2.10 keyboard filters

While browsing, Tab cycles All → Text → Images → All; Shift+Tab reverses. The active filter appears beside search with a Tab hint. Search stays focused, and the query is preserved when switching categories. ↑/↓ and Return operate only on matching entries. Image queries match source app names; OCR is not included. Opening G-Clip resets to All and clears the query. Tab in the editor remains normal text/control navigation.

## 0.2.11 copy-time labels

Copy-time labels show Just now for less than one minute, then whole minutes, hours or days. Seconds are not displayed. Labels refresh once per minute while visible; the underlying timestamps and retention behavior are unchanged.

## 0.2.12 plain preview, formatted editing

Text previews display the plain text in the app's standard reading style, including the chosen display-size setting. Opening Edit loads the original RTF/HTML formatting. New typing inherits the insertion point's style; standard paste into the editor matches that style rather than importing external formatting. Copy saves a new formatted entry while preserving the original. Default history paste remains plain; ⇧⌘V uses saved formatting.

## 0.2.13 menu organization

Right-click the menu-bar icon for these groups:

- Open/Hide G-Clip and Pause/Resume capture.
- Theme → System / Light / Dark; Font size → slider and live example.
- Keyboard shortcut → ⌥⌘Space / ⌃⌥Space; Launch at login; Direct paste permissions.
- Quit G-Clip.

Checkmarks identify the chosen theme, registered shortcut, enabled login item and granted direct-paste permission. Direct paste permissions opens the macOS settings; it is not an on/off permission toggle.

## 0.2.14 clearer permission label

The menu action is now Automatic pasting…, and the main-window prompt is Enable automatic pasting…. Tooltips explain that Enter pastes into the previous app and that macOS Accessibility permission is required. Behavior is unchanged.

## 0.2.15 permission-navigation wording

The menu and main-window permission action are labeled Open Accessibility Settings…. Its tooltip explains that it opens macOS permissions for automatic pasting. The menu checkmark was removed so the action does not resemble an in-app feature toggle.

## 0.2.16 — Compact workspace

The app icon now sits inside search, replacing the separate title/count header. Image tools share a compact toolbar with Copy beside Undo and Reset; text entry appears only for the Text tool. Image dimensions and format sit at the bottom right beside the unchanged small keyboard hints. Preview and text editing also use compact top actions. The adjustable, saved panel divider remains available.

## 0.3.0 — Movable annotations and zoom

- Click or drag an existing arrow/rectangle to select or move it. Drag on empty image space to keep drawing with the active tool. Text boxes accept typing immediately; clicking their text edits it and dragging their handle moves them.
- Delete/Backspace or × removes the selected annotation. While entering text, deletion edits characters. Escape finishes typing, then clears selection, then returns to browsing. ⌘← returns directly to browsing.
- Selection controls remain a constant size in window points, sit behind the drawing start, and stay inside the visible pane. They do not appear in exported PNGs. The × has no hover animation.
- The chosen tool, color, and sizes stay active when changing images during the session. Selecting another image while editing opens it in the editor. Unsaved edits are still discarded when leaving an image; Copy creates a new history item and preserves the original.
- Image preview and editing offer 1×–6× magnification relative to the default fitted view. Reset zoom recenters the image and restores that default view. Pan with the hand tool, Space-drag, or scrolling while zoomed. Trackpad pinch and Command-scroll adjust zoom. Zoom does not change export dimensions.
- Crop keeps remaining annotations editable at their new coordinates; undo restores the uncropped image and annotations.
- Dark appearance uses a dark warm/green background, a darker search field, and teal selection highlights inspired by the supplied Alfred reference. Light and System appearance remain available.

## 0.3.1 — Responsive image navigation and larger controls

Preview now owns a separate image draft and loads the selected clip directly, rather than relying on a view appearance callback shared with editing. Image decoding runs on a background queue; changing selection clears the old image immediately, cancels queued work, and rejects outdated completions. A bounded full-resolution cache and separate 96-pixel thumbnails avoid repeatedly decoding full images while browsing. Editing also loads in the background, with the last-used drawing tool preserved.

Image tools use 17–19 pt symbols in 32–34 pt targets. Zoom controls have matching targets and a clearer open-hand icon. The default window is now 1200 × 710 (previously 1100 × 650), and the divider reserves enough width for the larger image toolbar. The small keyboard hints retain their original font size.

## 0.3.2 — More image text sizes

Image annotation text offers 12, 18, 24, 32, 42, 54, and 64 pt. The initial size is 24 pt. Choosing a size also updates a selected annotation through the existing style controls.

## 0.3.3 — Floating-window paste

G-Clip captures the Accessibility keyboard recipient, focused window, and focused element before opening. This supports floating panels whose owner may differ from the foreground app reported by NSWorkspace. Its history window is now nonactivating, avoiding unnecessary app activation when opened. Closing it restores the captured panel/field before attempting ordinary app activation.

Automatic paste waits for the captured process/window/field to regain focus and for keyboard modifiers to be released, then sends one Command-V pair to the captured process. Clipboard-change and cancellation guards remain in place. If the original field cannot be restored, the item stays copied and a manual-paste message is shown instead of pasting into a different window. No input-field values are read or stored. Requires the installed app's existing Accessibility permission.

For Gemini's floating window, click its message input before pressing Option-Command-Space, then choose a clip. Gemini-specific live acceptance remains to be verified with the installed build.

## 0.3.4 — Image-control contrast

Enabled image-editing and zoom buttons now use an explicit near-white foreground in dark appearance and a dark foreground in light appearance. Selected tools use a stronger teal background. Color and size menus use the same brighter foreground instead of inheriting the dim window accent. Disabled controls remain visibly subdued.

Known issue: Gemini Mini Chat still dismisses when G-Clip takes keyboard focus. The prior floating-window paste change did not resolve that behavior; live investigation is pending. This release does not claim an additional Gemini paste fix.

## 0.3.5 — Reopen Gemini Mini Chat before paste

Live inspection confirmed that Gemini Mini Chat disappears when switching to G-Clip, and Gemini's native Open mini chat button restores the same chat and draft. For a destination captured as Gemini Mini Chat, G-Clip now locates that native button by its observed accessibility identifier and presses it once if the panel is no longer focused. It reacquires the recreated mini window and input field, and verifies the original chat-window title and focus before pasting. Cancellation also retries restoring the mini panel. Other apps keep the existing focus-restoration behavior. No Gemini prompt or response values are read, and no Submit action is used. The brighter controls from 0.3.4 are included.

The native Gemini reopening action was manually verified; automatic end-to-end paste in this build remains unverified because automation timed out accessing the G-Clip test panel.

## 0.3.6 — Screen-aware window sizing

The default window uses 88% of the display's usable width and height, capped at 1500 × 890 points (about 25% larger in each dimension than 1200 × 710). It opens centered on the screen containing the mouse pointer. The usual minimum is 980 × 540, relaxed when a smaller screen requires it, with a 16-point margin inside the usable screen area. Menu-bar and Dock space is excluded.

Manual resizing is remembered across launches. Automatic fitting on smaller screens or display changes does not overwrite the saved preference; returning to a larger display restores it. Switching between preview and editing keeps the current size. Users can manually resize larger than the default cap when the display permits it. Synthetic preview mode never saves window preferences.

## 0.3.7 — Higher placement and window dragging

The default window opens slightly above vertical center, shifted by one quarter of the spare vertical space, capped at 80 points. Screen margins still apply. Drag the G-Clip icon at the left of search to move the window; empty window background is also movable. Search text selection and image annotation gestures keep their existing behavior. Reopening uses the elevated default position; saved manual size is preserved.
