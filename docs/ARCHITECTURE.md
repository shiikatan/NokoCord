# NokoCord (Chiaki Edition) — Architecture Specification

This document provides a comprehensive technical overview of the architecture of **NokoCord (Chiaki Edition)**. It covers the high-level system design, the native-to-web boundary, process isolation, data flows, and component responsibilities for future maintainers and agents.

---

## 1. System Philosophy & Design Principles

NokoCord Chiaki is a high-performance, private, native macOS wrapper for Discord built using Swift, SwiftUI, and WebKit (`WKWebView`).

### Core Invariants & Rules
1. **Single Persistent WebKit Process**: All Discord authentication, gateway WebSockets, audio/video WebRTC media, and chat interactions occur within a single persistent `WKWebView`.
2. **Zero Raw Token Access / Zero Self-Botting**: Under no circumstances should NokoCord extract user authentication tokens, store Discord tokens, or inject network proxies that perform automated user actions ("self-botting"). Doing so violates Discord's Terms of Service and compromises user account safety.
3. **Local Capability-Restricted Extensions (Tans)**: Extensions (called "Tans") run in isolated JavaScript worlds or the page world under strict capability constraints (`appearance.read` is the only supported native capability in Schema 1).
4. **macOS Native Parity with Vesktop UX**: Deliver seamless macOS desktop behavior (native traffic lights insets, window drag regions, custom macOS overlay scrollbars, native notification center routing, native keyboard shortcuts, and zero-latency UI interactions) without running a resource-heavy Electron framework.
5. **Strict Process Hygiene & Memory Control**: Unlike standard browser tabs or Electron instances that freely expand to 2–3 GB of RAM, NokoCord continuously suppresses WebKit tile retention, manages graphics texture memory, prunes Discord Flux stores, and auto-pauses offscreen media.

---

## 2. Process Architecture & Boundaries

```mermaid
graph TD
    subgraph macOS Host System
        AppKit[NSApplication / SwiftUI App]
        NSSpell[NSSpellChecker Daemon]
        UNNotif[UNUserNotificationCenter]
        SysWorkspace[NSWorkspace / Process Scanner]
    end

    subgraph NokoCord Main Process (Swift / Native)
        AppEntry[NokoCordApp.swift]
        Delegate[NokoApplicationDelegate]
        BrowserEng[WKBrowserEngine]
        TanMgr[TanManager & TanStorage]
        TanRun[TanRuntime Swift Bridge]
        GamePres[GamePresenceService]
        NotifSvc[NotificationService]
        UIViews[SwiftUI Overlay Views]
        
        UIViews --> QuickSwitcher[QuickSwitcherView ⌘K]
        UIViews --> TansInspector[TansInspectorView ⌘T]
        UIViews --> Lightbox[NativeMediaViewer Modal]
        UIViews --> MenuBar[MenuBarExtra / Dock Status]
    end

    subgraph WebKit WebContent Process (discord.com)
        WKView[WKWebView]
        DOM[Discord DOM / React App Tree]
        InjectedScript[discordInjectedScript @atDocumentStart]
        TanPage[Page-World Tans]
        TanIsolated[Isolated-World Tans]
        FluxStores[Discord Webpack & Flux Stores]
    end

    AppEntry --> Delegate
    AppEntry --> BrowserEng
    BrowserEng --> TanRun
    BrowserEng --> NSSpell
    TanRun --> WKView
    GamePres --> SysWorkspace
    NotifSvc --> UNNotif

    InjectedScript -.->|Script Message Handler: nokoCordApp| TanRun
    TanIsolated -.->|Script Message Handler: nokoTan_*| TanRun
    TanRun --> InjectedScript
    DOM --> FluxStores
```

### Process Isolation Details
* **AppKit Host Process (`NokoCord`)**: Owns the native window, menu bar, system dock icon, settings, local disk storage for Tans (`~/Library/Application Support/NokoCord/`), and native overlay interfaces.
* **WebKit WebContent Process (`com.apple.WebKit.WebContent`)**: Runs out-of-process in a sandboxed auxiliary process. It renders `https://discord.com`, runs JavaScript, manages DOM rendering, and decodes audio/video streams.
* **WebKit Networking Process (`com.apple.WebKit.Networking`)**: Manages TLS sockets, HTTP/2 and WebSocket connections to Discord's gateway and CDN servers.
* **WebKit GPU Process (`com.apple.WebKit.GPU`)**: Handles hardware-accelerated canvas, WebGL, and Metal layer compositing.

---

## 3. Component Hierarchy & Source Layout

The repository is organized cleanly by functional domain:

```
NokoCord/
├── NokoCordApp.swift              # Application entry point, AppKit delegate, MenuBarExtra
├── ContentView.swift              # Root layout (NokoRootView), keyboard commands, split views
├── Discord/
│   ├── DiscordTypes.swift         # Gateway status enums, CDN URL formatters, safe parsers
│   └── DiscordConstants.swift     # Discord bundle identifiers, API origins, endpoints
├── Media/
│   └── NativeMediaViewer.swift    # Zero-memory modal media viewer (images, videos)
├── Models/
│   ├── EditionIdentity.swift      # Chiaki build metadata, versioning, edition tags
│   ├── BrowserPolicy.swift        # Whitelisted URLs, origin verifiers, navigation rules
│   ├── TanManifest.swift          # Tan package schema (v1), JSON validation, capabilities
│   └── TanPackage.swift           # Installed Tan metadata, SHA-256 integrity fingerprints
├── Persistence/
│   └── TanStorage.swift           # Disk operations for Tans (install, remove, enumerate)
├── Resources/
│   ├── Assets.xcassets            # Icons, branding marks (NokoMark)
│   └── Localizable.xcstrings      # Localized strings catalog
├── Services/
│   ├── BrowserEngine.swift        # WKBrowserEngine, WKPreferences, memory timers
│   ├── TanRuntime.swift           # Injected scripts, CSS overrides, bridge handlers
│   ├── TanManager.swift           # State machine for enabled/disabled/safe-mode Tans
│   ├── NotificationService.swift  # Native notification deliverer (UNUserNotificationCenter)
│   └── GamePresenceService.swift  # Running game process scanner for Rich Presence
└── Views/
    ├── QuickSwitcherView.swift    # Spotlight-style ⌘K command palette and channel finder
    ├── TansInspectorView.swift    # ⌘T developer inspector for installed Tan extensions
    ├── SettingsView.swift         # General preferences, developer mode, safe mode toggle
    ├── BrowserView.swift          # NSViewRepresentable wrapping the active WKWebView
    └── WebKitView.swift           # Low-level NSView host for WKWebView
```

---

## 4. Native to Web Bridge Architecture

Communication between Swift and Discord's JavaScript context is strictly managed via WebKit user content controllers.

### 1. `nokoCordApp` Script Message Handler
Registered on the main `WKUserContentController` for `discordInjectedScript`:

| Action | Direction | Payload | Handler Responsibility |
| :--- | :--- | :--- | :--- |
| `toggleTans` | Web -> Swift | `{ action: "toggleTans" }` | Toggles the native Tans Inspector sheet (`⌘T`). |
| `toggleQuickSwitcher` | Web -> Swift | `{ action: "toggleQuickSwitcher" }` | Toggles the native Command Palette (`⌘K`). |
| `toggleZenMode` | Web -> Swift | `{ action: "toggleZenMode" }` | Toggles Zen Mode sidebar collapse (`⌘\`). |
| `channelChanged` | Web -> Swift | `{ action: "channelChanged" }` | Notifies Swift of route changes for unread/presence sync. |
| `openMedia` | Web -> Swift | `{ action: "openMedia", url: String, isVideo: Bool }` | Opens native macOS Lightbox, bypassing Discord's React modal. |
| `notification` | Web -> Swift | `{ action: "notification", title: String, body: String }` | Routes HTML5 notifications to `UNUserNotificationCenter`. |

### 2. `nokoTan_<hash>` Script Message Handler
Dedicated handler instantiated per installed Tan package:
* Runs inside an isolated content world (`WKContentWorld.world(name: "NokoTan.<id>")`).
* Enforces strict origin matching (`https://discord.com/app` or `https://discord.com/channels/*`).
* Requires SHA-256 fingerprint verification matching the disk package hash.
* Rate-limited to 20 messages per second per Tan to prevent IPC flooding.
* Permitted requests: `{ type: "status", state: "started" | "stopped" | "failed" }` and `{ type: "capability", capability: "appearance.read" }`.

---

## 5. Security & Privacy Guarantees

1. **Sandboxing**: Hardened runtime enabled with entitlements restricted to audio input, camera capture, network client, and user-selected file read/write.
2. **Credential Isolation**: Web cookies, indexedDB, and localStorage are stored in a private persistent data store (`dataStore = .default()`), separate from standard Safari browsing sessions.
3. **No Dynamic Code Loading Over Network**: Tans cannot be fetched from remote HTTP endpoints. Every Tan must be a local folder containing a valid `manifest.json` and local source files, explicitly installed by the user.
4. **Safe Mode (`--safe-mode`)**: When launched with `--safe-mode` or enabled via settings, all injected Tan scripts are completely disabled. The web engine reloads with zero custom extensions, serving as an immutable recovery path.
