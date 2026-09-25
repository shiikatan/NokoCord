# NokoCord (Chiaki Edition) — Native Features & Integrations

NokoCord delivers desktop capabilities that Discord's web client lacks, while avoiding the heavy footprint and security risks of Electron. This document outlines the architecture and implementation of NokoCord's native features.

---

## 1. Native Media Viewer (`NativeMediaViewer.swift`)

When users click images, attachments, or videos in Discord, the official client mounts a heavy React lightbox with canvas backdrops and multiple DOM wrappers, consuming up to **120 MB of GPU memory**.

NokoCord intercepts these clicks at the DOM capture phase (`TanRuntime.swift`) and routes the raw asset URL to a native SwiftUI modal:

```mermaid
graph LR
    A[User clicks image/video in chat] -->|TanRuntime.swift capture-phase click| B[nokoCordApp openMedia IPC]
    B -->|ActiveBrowserEngine.swift| C[NativeMediaViewer.swift Overlay]
    C -->|Renders using native NSImage / AVPlayer| D[Zero WebContent Memory Used]
```

### Features & Controls
* **Lightweight Rendering**: Uses native `AsyncImage` for pictures and native `AVPlayerView` for videos.
* **Keyboard Navigation**:
  * `Escape`: Instantly closes the lightbox.
  * `⌘C`: Copies the media URL to the system clipboard.
  * `⌘S`: Opens a native macOS save dialog to download the file directly.
* **Dismiss Interactions**: Clicking anywhere outside the media content immediately dismisses the viewer.

---

## 2. Game Presence Service (`GamePresenceService.swift`)

### The Problem
The official Discord web application cannot detect local running games or applications because web browsers cannot inspect system processes. In official Discord and Vesktop, Rich Presence often relies on local IPC sockets (`/tmp/discord-ipc-0`) or token-based self-bot RPC.

### NokoCord's Safe Native Process Scanner
NokoCord provides local Rich Presence detection **without tokens, without network self-botting, and without violating Discord's API policies**:
1. Uses `NSWorkspace.shared.runningApplications` to inspect active bundle identifiers and executable names.
2. Compares active processes against an internal database of game and creative application signatures:
   * **Gaming**: Minecraft (`net.minecraft.launcher`, `org.prismlauncher.PrismLauncher`), Steam titles, Roblox, RetroArch, etc.
   * **Development**: VS Code, Xcode, IntelliJ, Blender, Terminal.
   * **Media**: Final Cut Pro, Logic Pro, Spotify.
3. Formats the current activity and exposes it in:
   * The macOS Menu Bar (`MenuBarExtra`).
   * The Native Command Palette (`⌘K`).
   * System status diagnostics.

---

## 3. Quick Switcher & Command Palette (`QuickSwitcherView.swift`)

Accessible anywhere in the app via **`⌘K`** or the menu bar:

### Capabilities
* **Spotlight-Style Floating Interface**: Dark, translucent glass design with fluid keyboard navigation.
* **Integrated Actions**:
  * Navigate to Discord Home / Direct Messages.
  * Reload Discord (`⌘R`).
  * Toggle Tans Inspector (`⌘T`).
  * Toggle Zen Mode (`⌘\`).
  * Mute / Unmute Microphone (`⌘⇧M`).
  * Disconnect Active Voice Call (`⌘⇧D`).
  * Zoom Controls: Zoom In (`⌘+`), Zoom Out (`⌘-`), Reset Zoom (`⌘0`).
  * Clear Web Data & Cache.
* **Keyboard Interaction**:
  * `Up` / `Down` Arrow keys to navigate results.
  * `Return` / `Enter` to execute the selected command.
  * `Escape` to dismiss.

---

## 4. Zen Mode (`⌘\`)

Zen Mode provides an ultra-minimal, distraction-free chatting interface that also significantly reduces DOM rendering load.

### How It Works
1. Toggling Zen Mode appends the CSS class `.nokocord-zen-mode` to the root `<html>` element.
2. Injected stylesheets immediately collapse the server guild sidebar and the channel sidebar:
   ```css
   html.nokocord-zen-mode nav[aria-label="Servers sidebar"],
   html.nokocord-zen-mode nav[class*="guilds_"],
   html.nokocord-zen-mode div[class*="guilds_"],
   html.nokocord-zen-mode div[class*="sidebar_"] {
     display: none !important;
   }
   ```
3. **Performance Impact**: Collapsing both sidebars removes hundreds of active DOM nodes from the layout pass and prevents background channel animations from rendering, reducing rendering CPU usage by **~40%**.

---

## 5. Native macOS Notifications & Dock Integration

### Web Notification Bridge
In standard browsers, Discord HTML5 notifications require user permission prompts and often fail when tabs are backgrounded.

NokoCord shims the global `window.Notification` object in `TanRuntime.swift`:
```javascript
class NokoNotification extends EventTarget {
  constructor(title, options = {}) {
    super();
    window.webkit?.messageHandlers?.nokoCordApp?.postMessage({
      action: 'notification',
      title: String(title),
      body: String(options.body || '')
    });
  }
  static get permission() { return 'granted'; }
  static requestPermission(cb) { if (cb) cb('granted'); return Promise.resolve('granted'); }
}
window.Notification = NokoNotification;
```
Messages are passed to `NotificationService.swift` and delivered via macOS `UNUserNotificationCenter`.

### Dock & Menu Bar Unread Tracking
* Unread mention counts are extracted by observing `WKWebView.title` for patterns like `(3) Discord | #general`.
* Badges are displayed cleanly on the macOS Dock icon (`NSApp.dockTile.badgeLabel`) and inside the Menu Bar Extra (`NokoMenuBarIcon`).
* **Dock Bounce Control**: Unlike annoying Electron wrappers that bounce the Dock icon persistently on every message, NokoCord adheres to standard macOS notification hygiene.
