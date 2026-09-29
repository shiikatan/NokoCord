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

## 2. Build and release identity

The command-line build and Xcode project are two views of the same source. The
release identity is canonical in `Config/Edition.xcconfig`; do not copy a
version or build number into a script, helper plist, or release note. The
release gate compares CLI and Xcode identities before packaging.

The project may be built from the command line using Apple's Command Line Tools
and `swiftc`, but a host missing XCTest, xcstringstool, or the full Xcode SDK
cannot claim a complete verification pass. Record the exact missing component
and continue only with independent checks.

### The Build Script (`scripts/build.sh`)
Execute the full build pipeline:
```bash
sh scripts/build.sh
```

### Build Pipeline Stages
`scripts/build.sh` prints one line per stage:

1. **[1/6] Directories**: creates `build/NokoCord.app/Contents/{MacOS,Resources,Helpers}`.
2. **[1/6] TanTranslator**: compiles `Tools/TanTranslator/Helper/main.swift` into `Contents/Helpers/TanTranslator`.
3. **[1b/6] NokoMusicWatch**: compiles `Tools/NokoMusicWatch/main.swift` into its own app bundle at `Contents/Helpers/NokoMusicWatch.app`, gives it an Info.plist and the app icon, and signs it ad-hoc **without** the hardened runtime and **without** entitlements. That shape is deliberate and is asserted by the verifier: macOS only offers Apple Events consent to a locally signed helper that is neither sandboxed nor hardened.
4. **[2/6] NokoCord binary**: compiles every Swift file under `NokoCord/` with
   `swiftc -parse-as-library -j<cores> <sources> -O`, against the SDK named by
   `SDKROOT` (the script falls back to the Command Line Tools SDK when the
   default one is missing). No `-framework` flags are needed: Swift autolinks
   from `import`.
5. **[3/6] Resources**: copies the branding mark, builds `AppIcon.icns` from
   `NokoCord/Assets.xcassets/AppIcon.appiconset`, and copies `Assets.xcassets`
   and `Localizable.xcstrings`.
6. **[4/6] Info.plist**: generates both plists from the canonical edition
   metadata — the app's edition identity, bundle ID, public version, URL scheme,
   and usage strings, plus the helper's matching identity.
7. **[5/6] Signing**: signs inside-out — the helper ad-hoc without the runtime,
   then the app ad-hoc with the hardened runtime and the sandbox entitlements
   from `Config/NokoCord.entitlements`.
8. **[6/6] Verification**: runs `scripts/verify-release.py` on the finished
   bundle and refuses to ship if any check fails.

The release checklist requires the Xcode Debug/Release and CLI paths to agree
on app/helper identity and deployment target. The shipping bundle is assembled
by `scripts/build.sh`; `scripts/verify.sh` verifies that bundle and the Xcode
build outputs rather than treating either path as an unreviewed substitute.

---

## 3. Release Verification & Quality Gates

Before any change is committed or tested, verify the release artifact:

```bash
python3 scripts/verify-release.py build/NokoCord.app --edition chiaki
```

### Verification Checks
* **Signature Integrity**: the app verifies as ad-hoc signed with the hardened
  runtime; the helper verifies without it.
* **Architecture Validation**: the executable contains `arm64`. Universal
  binaries are allowed but not required.
* **Entitlements Audit**: the app's entitlements must be exactly the reviewed
  sandbox set — anything new fails the release until it is reviewed. The helper
  must carry none.
* **Helper Identity**: its bundle id, `LSUIElement` flag and Apple Events usage
  description are asserted, because that shape is the reviewed exception that
  makes Music access possible at all.
* **Shipped-Byte Privacy Audit**: scans the bundle for development tokens, raw
  process notes and debug logs.
* **URL Scheme Validation**: the only registered scheme must be `nokocord`.

---

## 4. Critical Invariants & Pitfalls for Future Agents

### ⚠️ Pitfall 1: Breaking Chat Reverse-Scrolling
* **Never** apply `content-visibility: auto` or CSS layout containment to `[class*="messageListItem_"]`. Discord reverse-scrolls from the bottom; layout containment breaks element height calculations and causes the scroller to jitter backwards.
* **Never** swap `img.src` to a placeholder SVG while scrolling. Swapping `src` back when in view fires browser `onload` events that Discord hooks to adjust scroll anchors, throwing the scroll position backwards.

### ⚠️ Pitfall 2: Introducing Typing Lag in Chat
* **Never** run unbounded `MutationObserver` listeners that query `querySelectorAll` on DOM mutations without filtering.
* Always check if `mutation.target` is an editable element (`[contenteditable="true"]`, `[role="textbox"]`, `textarea`, `input`). If so, skip it and debounce with `requestAnimationFrame`.

### ⚠️ Pitfall 3: Incomplete Autocorrect/Autocomplete Suppression
* On modern macOS, registering `UserDefaults` is **not enough** to kill inline predictive text (grey ghost text).
* You must call `NSSpellChecker.shared` daemon methods directly:
  ```swift
  let checker = NSSpellChecker.shared
  checker.perform(NSSelectorFromString("setAutomaticInlinePredictionEnabled:"), with: false as NSNumber)
  checker.perform(NSSelectorFromString("setAutomaticInlineCompletionEnabled:"), with: false as NSNumber)
  ```
* In the page, suppression is a capture-phase `focusin` listener that sets
  `autocomplete="off"`, `spellcheck="false"`, `autocorrect="off"` and
  `autocapitalize="off"` on the focused editor. It deliberately does not
  override any prototype, because Discord's editor reads those attributes
  directly and prototype hooks are far more likely to break typing than to fix
  it.

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
  Launch NokoCord with `--safe-mode` to bypass all Tans, custom user scripts,
  message handlers, and app bridge handlers while keeping authentication intact:
  ```bash
  open build/NokoCord.app --args --safe-mode
  ```
