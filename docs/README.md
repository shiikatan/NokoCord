# NokoCord (Chiaki Edition) — Documentation Suite

Welcome to the comprehensive documentation suite for **NokoCord (Chiaki Edition)**, maintained by Millx.

NokoCord is a privacy-first, native macOS client wrapper for Discord built with Swift, SwiftUI, and WebKit (`WKWebView`). It provides a lightweight, battery-efficient alternative to Electron without sacrificing desktop conveniences.

---

## Documentation Index

| Document | Focus & Contents |
| :--- | :--- |
| **[Architecture Specification](ARCHITECTURE.md)** | System topology, process isolation boundaries, native-to-web IPC bridge, source layout, and security guarantees. |
| **[Performance & Memory Engineering Guide](PERFORMANCE_AND_MEMORY.md)** | Forensic memory analysis (`vmmap`/`heap`), WebKit memory policies, graphics texture optimization, reverse-scrolling physics, and typing latency solutions. |
| **[In-Page Runtime & DOM Engine](DOM_AND_RUNTIME.md)** | Injected script lifecycle, complete autocorrect/prediction eradication, Discord Flux/Webpack store hooking, and macOS styling. |
| **[Native Features & Integrations](NATIVE_FEATURES.md)** | Native Media Viewer (Lightbox), Game Presence local process scanner, Quick Switcher (`⌘K`), Zen Mode (`⌘\`), and Notifications. |
| **[Tans Extension System](TANS.md)** | Tan package manifest schema (v1), isolation contract, native capabilities boundary (`appearance.read`), and resource limits. |
| **[Developer & Agent Runbook](DEVELOPER_GUIDE.md)** | CLI build pipeline (`scripts/build.sh`), release verification, debugging workflows, and critical technical pitfalls for AI agents. |

---

## Quick Reference

### Building the Project
```bash
# Compile and package build/NokoCord.app (no Xcode required)
sh scripts/build.sh

# Verify release bundle integrity
python3 scripts/verify-release.py build/NokoCord.app --edition chiaki
```

### Running NokoCord
```bash
# Launch the built application
open build/NokoCord.app

# Launch in recovery Safe Mode (bypasses all Tans and custom scripts)
open build/NokoCord.app --args --safe-mode
```

### Keyboard Shortcuts
* **`⌘K`**: Open Quick Switcher / Command Palette.
* **`⌘T`**: Open Tans Inspector.
* **`⌘\`**: Toggle Zen Mode (collapses sidebars for distraction-free chat and 40% less rendering load).
* **`⌘R`**: Reload Discord web view.
* **`⌘⇧M`**: Toggle Microphone Mute.
* **`⌘⇧D`**: Disconnect Voice Call.
* **`⌘+` / `⌘-` / `⌘0`**: Zoom In / Zoom Out / Reset Zoom.
* **`Escape`**: Dismiss Quick Switcher, Tans Inspector, or Native Media Lightbox.
