# NokoCord (Chiaki Edition) — Developer & Agent Runbook

This guide contains the build commands, verification workflows, security policies, and technical pitfalls for future developers and AI coding agents working on **NokoCord (Chiaki Edition)**.

---

## 1. Branch Guidance & Repository Rules

Per `AGENTS.md`:
* **Checkout Identity**: This checkout is **Chiaki**, the experimental NokoCord edition maintained by Millx.
* **Branch Policy**: Work exclusively on branch `chiaki`. Do not merge or synchronize `maomao` or change the neutral `noko` landing branch.
* **Remote Git Policy**: Do not push or publish to any remote repository without explicit approval for the exact event.
* **Local Backups**: Maintain a local backup branch:
  ```bash
  git branch -f backup/chiaki-latest HEAD
  ```

---

## 2. Command-Line Build System (No Xcode Required)

NokoCord does not require the full Xcode IDE to compile. The entire project builds directly from the command line using Apple's Command Line Tools and `swiftc`.

### The Build Script (`scripts/build.sh`)
Execute the full build pipeline:
```bash
sh scripts/build.sh
```

### Build Pipeline Stages
1. **Directory Preparation**: Creates `build/NokoCord.app/Contents/MacOS`, `build/NokoCord.app/Contents/Resources`, and helper tool directories.
2. **TanTranslator Compilation**: Compiles the native Vencord-to-Tan AST translator helper (`Tools/TanTranslator/Sources/main.swift`) into `build/NokoCord.app/Contents/Helpers/TanTranslator`.
3. **NokoCord Binary Compilation**:
   Compiles all Swift source files in `NokoCord/` using `swiftc`:
   * Target: Apple Silicon (`arm64-apple-macos14.0`).
   * Linked Frameworks: `AppKit`, `WebKit`, `SwiftUI`, `CryptoKit`, `AVFoundation`, `UserNotifications`, `Observation`.
   * Compilation flags: `-O -whole-module-optimization -parse-as-library`.
4. **Asset & Resource Packaging**:
   Copies application icons (`Branding/NokoCord.icns`), assets, and helper binaries into the app bundle.
5. **Info.plist Generation**:
   Generates `Contents/Info.plist` declaring edition identity (`NokoCord Chiaki`), bundle ID (`com.shiikatan.nokocord`), version (`C1.0.0`), and URL schemes (`discord://`, `nokocord://`).
6. **Code Signing & Hardened Runtime**:
   Signs the bundle with ad-hoc identity (`-s -`), hardened runtime (`--options runtime`), and sandboxing entitlements (`Config/NokoCord.entitlements`).

---

## 3. Release Verification & Quality Gates

Before any change is committed or tested, verify the release artifact:

```bash
python3 scripts/verify-release.py build/NokoCord.app --edition chiaki
```

### Verification Checks
* **Signature Integrity**: Verifies valid ad-hoc/Developer ID signature and hardened runtime flags.
* **Architecture Validation**: Ensures universal or `arm64` binary architecture.
* **Entitlements Audit**: Confirms sandbox compliance without unauthorized permissions.
* **Shipped-Byte Privacy Audit**: Verifies that no private development tokens, raw process notes, or debug logs leaked into the bundle.
* **URL Scheme Validation**: Confirms proper registration of `discord://` and `nokocord://`.

---

## 4. Critical Invariants & Pitfalls for Future Agents

### ⚠️ Pitfall 1: Breaking Chat Reverse-Scrolling
* **Never** apply `content-visibility: auto` or CSS layout containment to `[class*="messageListItem_"]`. Discord reverse-scrolls from the bottom; layout containment breaks element height calculations and causes the scroller to jitter backwards.
* **Never** swap `img.src` to a placeholder SVG while scrolling. Swapping `src` back when in view fires browser `onload` events that Discord hooks to adjust scroll anchors, throwing the scroll position backwards.

### ⚠️ Pitfall 2: Introducing Typing Lag in Chat
* **Never** run unbounded `MutationObserver` listeners that query `querySelectorAll` on DOM mutations without filtering.
* Always check if `mutation.target` is an editable element (`[contenteditable="true"]`, `[role="textbox"]`, `textarea`, `input`). If so, skip it and debounce with `requestAnimationFrame`.

### ⚠️ Pitfall 3: Incomplete Autocorrect/Autocomplete Suppression
* On macOS 14+ (Sonoma/Sequoia), registering `UserDefaults` is **not enough** to kill inline predictive text (grey ghost text).
* You must call `NSSpellChecker.shared` daemon methods directly:
  ```swift
  let checker = NSSpellChecker.shared
  checker.perform(NSSelectorFromString("setAutomaticInlinePredictionEnabled:"), with: false as NSNumber)
  checker.perform(NSSelectorFromString("setAutomaticInlineCompletionEnabled:"), with: false as NSNumber)
  ```
* In the DOM, `autocomplete` does not exist on `HTMLElement.prototype`—it belongs to `HTMLInputElement.prototype` and `HTMLTextAreaElement.prototype`. Both must be overridden.

### ⚠️ Pitfall 4: Script Execution at `.atDocumentStart`
* `WKUserScript` with `.atDocumentStart` runs before `document.head` and `document.documentElement` exist.
* Always wrap DOM modifications in an `onReady()` helper checking `document.readyState`.

### ⚠️ Pitfall 5: Memory Leakage via Graphics Blur Textures
* Never introduce CSS `backdrop-filter: blur(...)` on high-frequency UI elements (menus, tooltips, modals). WebKit allocates persistent 2x Retina Metal backing textures for each blur, bloating memory by hundreds of megabytes. Use opaque high-contrast dark colors instead.

---

## 5. Testing & Debugging Workflow

* **Running the App Locally**:
  ```bash
  killall NokoCord 2>/dev/null || true
  open build/NokoCord.app
  ```
* **Inspecting WebKit Processes**:
  ```bash
  ps aux | grep -i "[N]okoCord"
  vmmap -summary <WebContent_PID>
  ```
* **Developer Mode & Web Inspector**:
  * Enable Developer Mode in Settings or via Tans Inspector (`⌘T`).
  * Right-click anywhere in Discord to access Safari Web Inspector.
* **Safe Mode Launch**:
  Launch NokoCord with `--safe-mode` to completely bypass all Tans and custom user scripts while keeping authentication intact:
  ```bash
  open build/NokoCord.app --args --safe-mode
  ```
