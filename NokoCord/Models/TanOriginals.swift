import Foundation

extension TanPackage {
    static let originals: [TanPackage] = [
        TanPackage(
            manifest: TanManifest(
                id: "noko.clear-focus",
                name: "Clear Focus",
                version: "1.2.0",
                description: "Make keyboard focus clear while preserving Discord’s existing focus treatment.",
                authors: ["shiikatan"],
                target: .isolated,
                entry: "main.js",
                stylesheet: "style.css"
            ),
            javascript: clearFocusJS,
            css: "[data-noko-focus]:focus-visible { outline: 2px solid #5b9dff !important; outline-offset: 2px !important; }",
            origin: "Noko-Tan"
        ),
        TanPackage(
            manifest: TanManifest(
                id: "noko.scroll-tools",
                name: "Scroll Tools",
                version: "1.1.0",
                description: "Move through the active panel, from loaded history to the newest content.",
                authors: ["shiikatan"],
                target: .isolated,
                entry: "main.js"
            ),
            javascript: scrollToolsJS,
            css: nil,
            origin: "Noko-Tan"
        ),
        TanPackage(
            manifest: TanManifest(
                id: "noko.chat",
                name: "Noko-Chat",
                version: "1.6.5",
                description: "A first-party Discord chat customization Tan with compact chat styling, avatar controls, composer cleanup, an optional Noko settings button, and a local image-to-GIF attachment utility.",
                authors: ["shiikatan"],
                target: .isolated,
                entry: "main.js"
            ),
            javascript: nokoChatJS,
            css: nil,
            origin: "Noko-Tan"
        ),
        TanPackage(
            manifest: TanManifest(
                id: "noko.morgana",
                name: "Morgana",
                version: "1.1.0",
                description: "Replaces Discord incoming message and mention notification pings with Morgana.",
                authors: ["Shiikatan"],
                target: .page,
                entry: "main.js",
                requiresReload: true
            ),
            javascript: morganaJS,
            css: nil,
            origin: "Noko-Tan"
        ),
    ]

    private static let clearFocusJS = ##"""
NokoTan.register({
  start(api) {
    let marked = null, frame = null;
    const clear = () => { marked?.deref()?.removeAttribute('data-noko-focus'); marked = null; if (frame !== null) cancelAnimationFrame(frame); frame = null; };
    const visible = style => (style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 1 && style.outlineColor !== 'transparent' && style.outlineColor !== 'rgba(0, 0, 0, 0)') || style.boxShadow !== 'none';
    const focus = event => {
      clear();
      const reference = new WeakRef(event.target);
      frame = requestAnimationFrame(() => {
        frame = null;
        const target = reference.deref();
        if (!(target instanceof Element) || !target.isConnected || !target.matches(':focus-visible')) return;
        // Inspect styling only, never text, inputs, credentials or session data.
        let element = target;
        for (let depth = 0; element && depth < 3; depth++, element = element.parentElement) {
          if (visible(getComputedStyle(element)) || visible(getComputedStyle(element, '::before')) || visible(getComputedStyle(element, '::after'))) return;
        }
        target.setAttribute('data-noko-focus', ''); marked = reference;
      });
    };
    api.listen(document, 'focusin', focus, true);
    api.listen(document, 'focusout', clear, true);
    api.onCleanup(clear);
  }
});
"""##

    private static let scrollToolsJS = ##"""
NokoTan.register({
  start(api) {
    let active = null;
    const bar = document.createElement('div');
    bar.setAttribute('data-noko-scroll-tools', '');
    bar.setAttribute('role', 'toolbar'); bar.setAttribute('aria-label', 'Noko scroll tools');
    bar.style.cssText = 'position:fixed;bottom:24px;right:24px;z-index:2147483000;display:flex;gap:2px;padding:4px;border:1px solid #ffffff28;border-radius:14px;background:#25252bf5;color:#f5eee4;box-shadow:0 3px 12px #0003;font:12px system-ui';
    const eligible = element => element instanceof Element && !bar.contains(element) && element.scrollHeight > element.clientHeight + 4 && /auto|scroll/.test(getComputedStyle(element).overflowY);
    const remember = element => { if (eligible(element)) active = new WeakRef(element); };
    const locate = event => {
      let element = event.target instanceof Element ? event.target : null;
      while (element && element !== document.documentElement) {
        if (eligible(element)) { remember(element); return; }
        element = element.parentElement;
      }
    };
    api.listen(document, 'scroll', event => remember(event.target), {capture:true, passive:true});
    api.listen(document, 'wheel', locate, {capture:true, passive:true});
    api.listen(document, 'focusin', locate, true);
    api.listen(document, 'pointerdown', event => { if (!bar.contains(event.target)) locate(event); }, true);
    for (const [label, glyph, end] of [['Earlier', '↑', false], ['Newest', '↓', true]]) {
      const button = document.createElement('button');
      button.textContent = glyph + ' ' + label;
      button.title = end ? 'Go to the end of the active panel' : 'Go to the start of loaded content. Discord may load earlier history; this is not an instant jump to the first message.';
      button.setAttribute('aria-label', button.title);
      button.style.cssText = 'color:inherit;background:transparent;border:0;padding:8px 11px;border-radius:10px;cursor:pointer;font:500 12px system-ui';
      api.listen(button, 'pointerenter', () => { button.style.background = '#ffffff14'; });
      api.listen(button, 'pointerleave', () => { button.style.background = 'transparent'; });
      api.listen(button, 'click', () => {
        const remembered = active?.deref();
        const target = remembered?.isConnected ? remembered : document.scrollingElement;
        target?.scrollTo({ top: end ? target.scrollHeight : 0, behavior: 'instant' });
      });
      bar.append(button);
    }
    api.mount(bar);
    return () => { active = null; };
  }
});
"""##

    private static let nokoChatJS = ##"""
NokoTan.register({
  start(api) {
    'use strict';

    // Noko-Chat 1.6.0
    // Pure DOM/CSS customization. No network requests, Discord tokens,
    // native bridge, helper process, or external service.

    const VERSION = '1.6.4';
    const STORAGE_KEY = 'noko.chat.settings.v1';

    const DEFAULTS = Object.freeze({
      density: 'compact',
      avatarShape: 'squircle',
      mentionStyle: 'soft',
      reactionSize: 'compact',
      mediaRounded: true,
      hideGift: true,
      hideGif: false,
      hideStickers: false,
      hideEmoji: false,
      hideApps: true,
      hideAvatarDecorations: false,
      showLauncher: true
    });

    const VALID = Object.freeze({
      density: new Set(['default', 'compact', 'extra-compact']),
      avatarShape: new Set(['circle', 'squircle', 'rounded', 'square']),
      mentionStyle: new Set(['discord', 'soft', 'outline', 'emphasized']),
      reactionSize: new Set(['default', 'compact', 'large'])
    });

    let settings = { ...DEFAULTS };
    let storageAvailable = true;
    let panelHost = null;
    let launcherRAF = 0;
    let attachObserver = null;
    let cancelAttachTimeout = null;
    let pickerRAF = 0;
    let pickerObserver = null;
    let cancelPickerTimeout = null;
    let gifToastHost = null;
    let cancelGifToastTimeout = null;
    let converterBusy = false;
    let disposed = false;
    const NATIVE_HANDLER_NAME = 'nokoTan_fd85b8335ab5d5c6c75fcf106db70759e586848715723d31cf98bf7f9d5ba4df';

    function sanitize(candidate) {
      const next = { ...DEFAULTS };
      if (!candidate || typeof candidate !== 'object') return next;

      for (const key of ['density', 'avatarShape', 'mentionStyle', 'reactionSize']) {
        if (VALID[key].has(candidate[key])) next[key] = candidate[key];
      }

      for (const key of [
        'mediaRounded',
        'hideGift',
        'hideGif',
        'hideStickers',
        'hideEmoji',
        'hideApps',
        'hideAvatarDecorations',
        'showLauncher'
      ]) {
        if (typeof candidate[key] === 'boolean') next[key] = candidate[key];
      }

      return next;
    }

    function loadSettings() {
      try {
        const raw = globalThis.localStorage?.getItem(STORAGE_KEY);
        settings = raw ? sanitize(JSON.parse(raw)) : { ...DEFAULTS };
      } catch {
        storageAvailable = false;
        settings = { ...DEFAULTS };
      }
    }

    function saveSettings(candidate = settings) {
      try {
        globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(sanitize(candidate)));
      } catch {
        storageAvailable = false;
      }
    }

    function nativeHandlerIsInstalled() {
      // TanRuntime removes this package's WKScriptMessageHandler before it
      // stops Noko-Chat for a genuine disable. During Discord reloads, SPA
      // navigation, pageDidLoad re-registration, and unrelated Tan changes,
      // Noko-Chat's handler remains installed (or is immediately reinstalled).
      // That gives us a native lifecycle signal without timers or pagehide
      // heuristics.
      try {
        const handler = globalThis.webkit?.messageHandlers?.[NATIVE_HANDLER_NAME];
        return !!handler && typeof handler.postMessage === 'function';
      } catch {
        return false;
      }
    }

    function restoreLauncherPreferenceAfterRealDisable() {
      if (nativeHandlerIsInstalled()) return;
      try {
        const raw = globalThis.localStorage?.getItem(STORAGE_KEY);
        const current = raw ? sanitize(JSON.parse(raw)) : { ...settings };
        current.showLauncher = true;
        globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(sanitize(current)));
      } catch {}
    }

    const style = document.createElement('style');
    style.id = 'noko-chat-style';
    style.textContent = `
/*
 * Noko-Chat intentionally scopes every rule to stable message/content IDs,
 * the active composer, or Noko-owned elements. Avoid broad class-substring
 * rules because Discord reply previews and unrelated controls reuse fragments.
 */

/* -------------------- Message density -------------------- */
/*
 * Keep Discord's group-start margins intact. The unread/new-message divider is
 * positioned relative to those gaps, and collapsing them can make the divider
 * cut through avatars/usernames. Compactness is limited to the message row's
 * own vertical padding so special separators/replies keep their geometry.
 */
html[data-noko-chat-density="compact"] li[id^="chat-messages-"] > :is([class^="message_"], [class*=" message_"]) {
  padding-top: 1px !important;
  padding-bottom: 1px !important;
}
html[data-noko-chat-density="extra-compact"] li[id^="chat-messages-"] > :is([class^="message_"], [class*=" message_"]) {
  padding-top: 0 !important;
  padding-bottom: 0 !important;
}

/* -------------------- Avatar shape -------------------- */
/*
 * Discord's main message avatar lives inside the message contents node, not
 * directly under the message wrapper. Scope to that subtree so reply-preview,
 * embed, member-list and popout avatars are untouched while tolerating Discord
 * inserting a harmless wrapper around the image.
 */
html[data-noko-chat-avatar="circle"] li[id^="chat-messages-"] :is([class^="contents_"], [class*=" contents_"]) img:is([class^="avatar_"], [class*=" avatar_"]) {
  border-radius: 50% !important;
}
html[data-noko-chat-avatar="squircle"] li[id^="chat-messages-"] :is([class^="contents_"], [class*=" contents_"]) img:is([class^="avatar_"], [class*=" avatar_"]) {
  border-radius: 28% !important;
}
html[data-noko-chat-avatar="rounded"] li[id^="chat-messages-"] :is([class^="contents_"], [class*=" contents_"]) img:is([class^="avatar_"], [class*=" avatar_"]) {
  border-radius: 18% !important;
}
html[data-noko-chat-avatar="square"] li[id^="chat-messages-"] :is([class^="contents_"], [class*=" contents_"]) img:is([class^="avatar_"], [class*=" avatar_"]) {
  border-radius: 2px !important;
}

/* Hide only decorations attached to avatars inside chat messages. */
html[data-noko-chat-hide-avatar-decorations="true"] li[id^="chat-messages-"] :is(
  [class^="avatarDecoration_"],
  [class*=" avatarDecoration_"],
  [class^="avatarDecorationWrapper_"],
  [class*=" avatarDecorationWrapper_"]
) {
  display: none !important;
}

/* -------------------- Mention styling -------------------- */
/* Only the real message-content node. This deliberately excludes reply previews. */
html[data-noko-chat-mentions="soft"] [id^="message-content-"] :is(span, a)[class*="mention"] {
  border-radius: 5px !important;
  padding-inline: 3px !important;
  background: color-mix(in srgb, currentColor 14%, transparent) !important;
  text-decoration: none !important;
  box-decoration-break: clone;
  -webkit-box-decoration-break: clone;
}
html[data-noko-chat-mentions="outline"] [id^="message-content-"] :is(span, a)[class*="mention"] {
  border-radius: 5px !important;
  padding-inline: 3px !important;
  background: transparent !important;
  box-shadow: inset 0 0 0 1px color-mix(in srgb, currentColor 38%, transparent) !important;
  text-decoration: none !important;
  box-decoration-break: clone;
  -webkit-box-decoration-break: clone;
}
html[data-noko-chat-mentions="emphasized"] [id^="message-content-"] :is(span, a)[class*="mention"] {
  border-radius: 5px !important;
  padding-inline: 4px !important;
  font-weight: 650 !important;
  background: color-mix(in srgb, currentColor 22%, transparent) !important;
  text-decoration: none !important;
  box-decoration-break: clone;
  -webkit-box-decoration-break: clone;
}

/* -------------------- Reactions -------------------- */
html[data-noko-chat-reactions="compact"] li[id^="chat-messages-"] :is([class^="reaction_"], [class*=" reaction_"]) {
  min-height: 22px !important;
}
html[data-noko-chat-reactions="compact"] li[id^="chat-messages-"] :is([class^="reactionInner_"], [class*=" reactionInner_"]) {
  padding: 1px 5px !important;
  gap: 3px !important;
}
html[data-noko-chat-reactions="large"] li[id^="chat-messages-"] :is([class^="reaction_"], [class*=" reaction_"]) {
  min-height: 30px !important;
}
html[data-noko-chat-reactions="large"] li[id^="chat-messages-"] :is([class^="reactionInner_"], [class*=" reactionInner_"]) {
  padding: 4px 8px !important;
  gap: 5px !important;
}
html[data-noko-chat-reactions="large"] li[id^="chat-messages-"] :is([class^="reaction_"], [class*=" reaction_"]) img {
  width: 20px !important;
  height: 20px !important;
}

/* -------------------- Media -------------------- */
html[data-noko-chat-media-rounded="true"] li[id^="chat-messages-"] :is([class^="imageWrapper_"], [class*=" imageWrapper_"]),
html[data-noko-chat-media-rounded="true"] li[id^="chat-messages-"] :is([class^="imageWrapper_"], [class*=" imageWrapper_"]) img,
html[data-noko-chat-media-rounded="true"] li[id^="chat-messages-"] :is([class^="imageWrapper_"], [class*=" imageWrapper_"]) video {
  border-radius: 12px !important;
}

/* -------------------- Code blocks -------------------- */
li[id^="chat-messages-"] pre {
  border-radius: 10px !important;
}

/* -------------------- Composer cleanup -------------------- */
html[data-noko-chat-hide-gift="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label*="gift" i] {
  display: none !important;
}
html[data-noko-chat-hide-gif="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label*="GIF" i] {
  display: none !important;
}
html[data-noko-chat-hide-stickers="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label*="sticker" i] {
  display: none !important;
}
html[data-noko-chat-hide-emoji="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label*="emoji" i] {
  display: none !important;
}
html[data-noko-chat-hide-apps="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label="Apps" i],
html[data-noko-chat-hide-apps="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label*="Launch Apps" i],
html[data-noko-chat-hide-apps="true"] :is([class^="channelTextArea_"], [class*=" channelTextArea_"]) :is(button,[role="button"])[aria-label*="app launcher" i] {
  display: none !important;
}

/* -------------------- Noko-Chat composer launcher -------------------- */
/*
 * Own the launcher's visuals instead of borrowing Discord's hashed button
 * class. Discord's action classes can contain hover/selected-state rules and
 * pseudo-elements, which made the Noko mark disappear at rest and jump into a
 * large rounded tile on hover. The custom button keeps a small, transparent
 * hit target while still living in Discord's real composer action row.
 */
#noko-chat-launcher {
  appearance: none;
  -webkit-appearance: none;
  box-sizing: border-box;
  flex: 0 0 40px;
  width: 40px;
  height: 40px;
  min-width: 40px;
  min-height: 40px;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: 8px;
  background: transparent !important;
  color: var(--interactive-normal, #b5bac1);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  align-self: center;
  line-height: 1;
  cursor: pointer;
  box-shadow: none !important;
  transform: none !important;
  opacity: 1 !important;
}
#noko-chat-launcher:hover {
  background: transparent !important;
  color: var(--interactive-hover, #dbdee1);
  box-shadow: none !important;
  transform: none !important;
}
#noko-chat-launcher:active {
  background: transparent !important;
  color: var(--interactive-active, #f2f3f5);
}
#noko-chat-launcher:focus-visible {
  outline: 2px solid #0a84ff;
  outline-offset: -2px;
}
#noko-chat-launcher::before,
#noko-chat-launcher::after {
  content: none !important;
}
#noko-chat-launcher .noko-chat-mark {
  width: 30px;
  height: 30px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
}
#noko-chat-launcher .noko-chat-letter {
  display: block;
  font: 800 22px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  letter-spacing: -0.55px;
  transform: translateY(.25px);
}
#noko-chat-launcher .noko-chat-dots {
  align-self: flex-start;
  display: inline-flex;
  flex-direction: column;
  gap: 3px;
  margin: 5px 0 0 2px;
  pointer-events: none;
}
#noko-chat-launcher .noko-chat-dot {
  width: 4px;
  height: 4px;
  border-radius: 50%;
  background: currentColor;
  flex: 0 0 4px;
}
`;

    function boolAttr(value) {
      return value ? 'true' : 'false';
    }

    function applySettings() {
      const root = document.documentElement;
      root.dataset.nokoChatDensity = settings.density;
      root.dataset.nokoChatAvatar = settings.avatarShape;
      root.dataset.nokoChatMentions = settings.mentionStyle;
      root.dataset.nokoChatReactions = settings.reactionSize;
      root.dataset.nokoChatMediaRounded = boolAttr(settings.mediaRounded);
      root.dataset.nokoChatHideGift = boolAttr(settings.hideGift);
      root.dataset.nokoChatHideGif = boolAttr(settings.hideGif);
      root.dataset.nokoChatHideStickers = boolAttr(settings.hideStickers);
      root.dataset.nokoChatHideEmoji = boolAttr(settings.hideEmoji);
      root.dataset.nokoChatHideApps = boolAttr(settings.hideApps);
      root.dataset.nokoChatHideAvatarDecorations = boolAttr(settings.hideAvatarDecorations);
      // Retire legacy attributes from 1.0-1.4 if a hot reload skipped an older cleanup.
      delete root.dataset.nokoChatCodeWrap;
      delete root.dataset.nokoChatQuietSystem;
      delete root.dataset.nokoChatSubtleHover;
    }

    function clearRootState() {
      const root = document.documentElement;
      for (const key of [
        'nokoChatDensity',
        'nokoChatAvatar',
        'nokoChatMentions',
        'nokoChatReactions',
        'nokoChatMediaRounded',
        'nokoChatHideGift',
        'nokoChatHideGif',
        'nokoChatHideStickers',
        'nokoChatHideEmoji',
        'nokoChatHideApps',
        'nokoChatHideAvatarDecorations',
        'nokoChatQuietSystem',
        'nokoChatSubtleHover',
        'nokoChatCodeWrap'
      ]) {
        delete root.dataset[key];
      }
    }

    function closeSettings() {
      panelHost?.remove();
      panelHost = null;
    }

    function option(value, label, selected) {
      return `<option value="${value}"${selected === value ? ' selected' : ''}>${label}</option>`;
    }

    function checked(value) {
      return value ? ' checked' : '';
    }

    function openSettings() {
      if (panelHost?.isConnected) return;

      panelHost = document.createElement('div');
      panelHost.id = 'noko-chat-settings-host';
      panelHost.style.cssText = 'position:fixed;inset:0;z-index:2147483646;pointer-events:none;';
      const shadow = panelHost.attachShadow({ mode: 'open' });

      shadow.innerHTML = `
<style>
  :host { all: initial; }
  * { box-sizing: border-box; }
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0,0,0,.18);
    pointer-events: auto;
  }
  .panel {
    position: fixed;
    right: 18px;
    bottom: 76px;
    width: min(360px, calc(100vw - 36px));
    max-height: min(620px, calc(100vh - 100px));
    overflow: auto;
    padding: 18px;
    border: 1px solid rgba(255,255,255,.13);
    border-radius: 16px;
    background: rgba(24,25,28,.97);
    color: #f2f3f5;
    box-shadow: 0 18px 60px rgba(0,0,0,.42);
    font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    pointer-events: auto;
  }
  .header { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:14px; }
  h1 { font-size:16px; line-height:1.2; margin:0; font-weight:700; }
  .sub { color:#b5bac1; font-size:11px; margin-top:3px; }
  .close {
    width:28px; height:28px; border:0; border-radius:8px; cursor:pointer;
    color:#dbdee1; background:rgba(255,255,255,.07); font-size:18px; line-height:1;
  }
  .close:hover { background:rgba(255,255,255,.11); }
  .section { border-top:1px solid rgba(255,255,255,.09); padding-top:13px; margin-top:13px; }
  .section:first-of-type { border-top:0; padding-top:0; margin-top:0; }
  .section-title { color:#b5bac1; font-size:11px; font-weight:700; letter-spacing:.04em; text-transform:uppercase; margin:0 0 8px; }
  label.row { display:flex; align-items:center; justify-content:space-between; gap:12px; min-height:32px; }
  label.row + label.row { margin-top:5px; }
  .label { min-width:0; }
  select {
    max-width:160px; min-width:126px; border:1px solid rgba(255,255,255,.12); border-radius:8px;
    padding:6px 28px 6px 8px; background:#111214; color:#f2f3f5; font:inherit;
  }
  input[type="checkbox"] {
    appearance:none; -webkit-appearance:none;
    width:17px; height:17px; margin:0;
    border:1px solid rgba(255,255,255,.28); border-radius:5px;
    background:#111214; cursor:pointer; position:relative;
    flex:0 0 auto;
  }
  input[type="checkbox"]:hover { border-color:rgba(255,255,255,.48); }
  input[type="checkbox"]:focus-visible { outline:2px solid #0a84ff; outline-offset:2px; }
  input[type="checkbox"]:checked { background:#0a84ff; border-color:#0a84ff; }
  input[type="checkbox"]:checked::after {
    content:""; position:absolute;
    left:5px; top:2px; width:4px; height:8px;
    border:solid #fff; border-width:0 2px 2px 0;
    transform:rotate(45deg);
  }
  .launcher-warning {
    margin-top:14px; padding:9px 10px; border-radius:9px;
    background:rgba(10,132,255,.10); border:1px solid rgba(10,132,255,.25);
    color:#b9d9ff; font-size:10.5px; line-height:1.35;
  }
  .launcher-warning[hidden] { display:none; }
  .footer { display:flex; justify-content:space-between; align-items:center; gap:10px; margin-top:16px; }
  .hint { color:#949ba4; font-size:10px; }
  .reset { border:1px solid rgba(255,255,255,.12); border-radius:8px; padding:6px 9px; cursor:pointer; background:#111214; color:#dbdee1; font:inherit; }
  .reset:hover { background:#1e1f22; }
</style>
<div class="backdrop" data-action="close"></div>
<div class="panel" role="dialog" aria-label="Noko-Chat settings">
  <div class="header">
    <div>
      <h1>Noko-Chat</h1>
      <div class="sub">Chat appearance and clutter controls · v${VERSION}</div>
    </div>
    <button class="close" type="button" data-action="close" aria-label="Close">×</button>
  </div>

  <div class="section">
    <div class="section-title">Messages</div>
    <label class="row"><span class="label">Density</span><select data-setting="density">
      ${option('default', 'Discord default', settings.density)}
      ${option('compact', 'Compact', settings.density)}
      ${option('extra-compact', 'Extra compact', settings.density)}
    </select></label>
    <label class="row"><span class="label">Avatar shape</span><select data-setting="avatarShape">
      ${option('circle', 'Circle', settings.avatarShape)}
      ${option('squircle', 'Squircle', settings.avatarShape)}
      ${option('rounded', 'Rounded square', settings.avatarShape)}
      ${option('square', 'Square', settings.avatarShape)}
    </select></label>
    <label class="row"><span class="label">Hide avatar decorations</span><input type="checkbox" data-setting="hideAvatarDecorations"${checked(settings.hideAvatarDecorations)}></label>
  </div>

  <div class="section">
    <div class="section-title">Mentions & reactions</div>
    <label class="row"><span class="label">Mention style</span><select data-setting="mentionStyle">
      ${option('discord', 'Discord default', settings.mentionStyle)}
      ${option('soft', 'Soft', settings.mentionStyle)}
      ${option('outline', 'Outline', settings.mentionStyle)}
      ${option('emphasized', 'Emphasized', settings.mentionStyle)}
    </select></label>
    <label class="row"><span class="label">Reaction size</span><select data-setting="reactionSize">
      ${option('default', 'Discord default', settings.reactionSize)}
      ${option('compact', 'Compact', settings.reactionSize)}
      ${option('large', 'Large', settings.reactionSize)}
    </select></label>
  </div>

  <div class="section">
    <div class="section-title">Composer</div>
    <label class="row"><span class="label">Hide Gift</span><input type="checkbox" data-setting="hideGift"${checked(settings.hideGift)}></label>
    <label class="row"><span class="label">Hide GIF</span><input type="checkbox" data-setting="hideGif"${checked(settings.hideGif)}></label>
    <label class="row"><span class="label">Hide Stickers</span><input type="checkbox" data-setting="hideStickers"${checked(settings.hideStickers)}></label>
    <label class="row"><span class="label">Hide Emoji</span><input type="checkbox" data-setting="hideEmoji"${checked(settings.hideEmoji)}></label>
    <label class="row"><span class="label">Hide Apps</span><input type="checkbox" data-setting="hideApps"${checked(settings.hideApps)}></label>
  </div>

  <div class="section">
    <div class="section-title">Noko-Chat</div>
    <label class="row"><span class="label">Show Noko button</span><input type="checkbox" data-setting="showLauncher"${checked(settings.showLauncher)}></label>
  </div>

  <div class="section">
    <div class="section-title">Media</div>
    <label class="row"><span class="label">Rounded media</span><input type="checkbox" data-setting="mediaRounded"${checked(settings.mediaRounded)}></label>
  </div>

  <div class="launcher-warning" data-launcher-warning${settings.showLauncher ? ' hidden' : ''}>
    Noko button hidden. After you close this panel, reopen it with ⌃⌥N. It stays hidden through Discord reloads and returns when Noko-Chat is disabled and re-enabled.
  </div>

  <div class="footer">
    <div class="hint">Composer N button · ⌃⌥N${storageAvailable ? '' : ' · persistence unavailable'}</div>
    <button class="reset" type="button" data-action="reset">Reset</button>
  </div>
</div>`;

      document.documentElement.appendChild(panelHost);

      shadow.addEventListener('click', event => {
        const action = event.target?.closest?.('[data-action]')?.dataset?.action;
        if (action === 'close') closeSettings();
        if (action === 'reset') {
          settings = { ...DEFAULTS };
          saveSettings();
          applySettings();
          applyLauncherPreference();
          closeSettings();
          openSettings();
        }
      });

      shadow.addEventListener('change', event => {
        const control = event.target?.closest?.('[data-setting]');
        if (!control) return;
        const key = control.dataset.setting;
        if (!(key in DEFAULTS)) return;

        const value = control instanceof HTMLInputElement && control.type === 'checkbox'
          ? control.checked
          : control.value;

        settings = sanitize({ ...settings, [key]: value });
        saveSettings();
        applySettings();
        if (key === 'showLauncher') {
          applyLauncherPreference();
          const warning = shadow.querySelector('[data-launcher-warning]');
          if (warning) warning.hidden = settings.showLauncher;
        }
      });
    }

    function toggleSettings() {
      if (panelHost?.isConnected) closeSettings();
      else openSettings();
    }

    /* -------------------- Image -> GIF utility -------------------- */
    const gifInput = document.createElement('input');
    gifInput.type = 'file';
    gifInput.accept = 'image/*';
    gifInput.tabIndex = -1;
    gifInput.setAttribute('aria-hidden', 'true');
    gifInput.style.cssText = 'position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;left:-10000px;top:-10000px;';

    function stopPickerObserver() {
      pickerObserver?.disconnect();
      pickerObserver = null;
      cancelPickerTimeout?.();
      cancelPickerTimeout = null;
      if (pickerRAF) cancelAnimationFrame(pickerRAF);
      pickerRAF = 0;
    }

    function normalizedLabel(element) {
      if (!(element instanceof Element)) return '';
      return (element.getAttribute('aria-label') || element.textContent || '')
        .replace(/\s+/g, ' ')
        .trim()
        .toLowerCase();
    }

    function corePickerLabel(element) {
      const label = normalizedLabel(element);
      return label === 'gif' || label === 'gifs' || label === 'stickers' || label === 'emoji';
    }

    function findGifPickerTabCluster() {
      const candidates = document.querySelectorAll('[role="tab"], button');
      for (const candidate of candidates) {
        if (!visible(candidate) || !corePickerLabel(candidate)) continue;

        let ancestor = candidate.parentElement;
        for (let depth = 0; ancestor && depth < 4; depth += 1, ancestor = ancestor.parentElement) {
          const rect = ancestor.getBoundingClientRect();
          if (!rect.width || !rect.height || rect.height > 120) continue;

          const peers = [...ancestor.querySelectorAll('[role="tab"], button')]
            .filter(peer => visible(peer) && corePickerLabel(peer));
          const labels = new Set(peers.map(normalizedLabel));
          const families = [
            [...labels].some(label => label === 'gif' || label === 'gifs'),
            labels.has('stickers'),
            labels.has('emoji')
          ].filter(Boolean).length;
          if (families < 2) continue;

          const inactive = peers.find(peer => peer.getAttribute('aria-selected') === 'false') ||
            peers.find(peer => peer !== candidate && peer.getAttribute('aria-selected') !== 'true') ||
            peers[peers.length - 1];
          if (!inactive) continue;

          const sameParent = peers.filter(peer => peer.parentElement === inactive.parentElement);
          return {
            container: sameParent.length >= 2 ? inactive.parentElement : ancestor,
            reference: inactive
          };
        }
      }
      return null;
    }

    function replaceFirstVisibleText(root, text) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let first = null;
      const extras = [];
      while (walker.nextNode()) {
        const node = walker.currentNode;
        if (!node.nodeValue?.trim()) continue;
        if (!first) first = node;
        else extras.push(node);
      }
      if (!first) {
        root.textContent = text;
        return;
      }
      first.nodeValue = text;
      for (const node of extras) node.nodeValue = '';
    }

    function ensureGifConverterTab() {
      const existing = document.querySelector('[data-noko-chat-gif-converter="true"]');
      if (existing?.isConnected) return true;

      const cluster = findGifPickerTabCluster();
      if (!cluster?.container || !cluster.reference) return false;

      const button = cluster.reference.cloneNode(true);
      button.removeAttribute('id');
      button.removeAttribute('aria-controls');
      button.removeAttribute('aria-describedby');
      button.removeAttribute('data-list-item-id');
      button.removeAttribute('data-state');
      button.setAttribute('data-noko-chat-gif-converter', 'true');
      button.setAttribute('aria-label', 'Convert image to GIF');
      if (button.hasAttribute('aria-selected')) button.setAttribute('aria-selected', 'false');
      if (button instanceof HTMLButtonElement) button.type = 'button';
      replaceFirstVisibleText(button, 'Convert');

      cluster.container.appendChild(button);
      return true;
    }

    function schedulePickerTab() {
      if (pickerRAF) return;
      pickerRAF = requestAnimationFrame(() => {
        pickerRAF = 0;
        if (ensureGifConverterTab()) stopPickerObserver();
      });
    }

    function armPickerObserver(watchForReplacement = false, lifetime = 1800) {
      const attached = ensureGifConverterTab();
      if (pickerObserver || (attached && !watchForReplacement)) return;

      const root = document.body || document.documentElement;
      pickerObserver = new MutationObserver(() => {
        const converter = document.querySelector('[data-noko-chat-gif-converter="true"]');
        if (!converter?.isConnected) schedulePickerTab();
      });
      pickerObserver.observe(root, { childList: true, subtree: true });
      cancelPickerTimeout = api.timeout(() => {
        cancelPickerTimeout = null;
        stopPickerObserver();
      }, lifetime);
    }

    function ensureGifToast() {
      if (gifToastHost?.isConnected) return gifToastHost;
      gifToastHost = document.createElement('div');
      gifToastHost.id = 'noko-chat-gif-toast-host';
      gifToastHost.style.cssText = 'position:fixed;left:50%;bottom:88px;transform:translateX(-50%);z-index:2147483647;pointer-events:none;';
      const shadow = gifToastHost.attachShadow({ mode: 'open' });
      shadow.innerHTML = `
<style>
  :host { all: initial; }
  .toast {
    max-width:min(460px,calc(100vw - 32px));
    padding:9px 12px;
    border:1px solid rgba(255,255,255,.12);
    border-radius:10px;
    background:rgba(17,18,20,.96);
    color:#f2f3f5;
    box-shadow:0 8px 28px rgba(0,0,0,.34);
    font:12px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
    text-align:center;
    white-space:normal;
  }
  .toast[data-kind="error"] { border-color:rgba(242,63,67,.42); color:#ffb8ba; }
  .toast[data-kind="success"] { border-color:rgba(35,165,89,.34); }
</style>
<div class="toast" role="status" aria-live="polite"></div>`;
      document.documentElement.appendChild(gifToastHost);
      return gifToastHost;
    }

    function showGifToast(message, kind = 'info', duration = 2600) {
      cancelGifToastTimeout?.();
      cancelGifToastTimeout = null;
      const host = ensureGifToast();
      const toast = host.shadowRoot?.querySelector('.toast');
      if (toast) {
        toast.textContent = message;
        toast.dataset.kind = kind;
      }
      if (duration > 0) {
        cancelGifToastTimeout = api.timeout(() => {
          cancelGifToastTimeout = null;
          gifToastHost?.remove();
          gifToastHost = null;
        }, duration);
      }
    }

    function safeGifName(name) {
      const base = String(name || 'image').replace(/\.[^./\\]+$/, '').trim() || 'image';
      return `${base}.gif`;
    }

    function findComposerEditor() {
      const editors = document.querySelectorAll(
        '[role="textbox"][contenteditable="true"][data-slate-editor="true"], [role="textbox"][contenteditable="true"]'
      );
      for (const editor of editors) {
        if (visible(editor)) return editor;
      }
      return null;
    }

    function composerContainer(editor) {
      if (!(editor instanceof Element)) return null;
      return editor.closest('form') ||
        editor.closest('[class*="channelTextArea_"]') ||
        editor.closest('[class*="form_"]') ||
        editor.parentElement;
    }

    function inputHint(input) {
      return [
        input.accept,
        input.name,
        input.id,
        input.getAttribute('aria-label'),
        typeof input.className === 'string' ? input.className : ''
      ].filter(Boolean).join(' ').toLowerCase();
    }

    function uploadInputScore(input, editor) {
      if (!(input instanceof HTMLInputElement) || input === gifInput || input.disabled || !input.isConnected) return -Infinity;
      const accept = (input.accept || '').toLowerCase();
      if (accept && !accept.includes('image') && !accept.includes('gif') && !accept.includes('*/*')) return -Infinity;

      let score = 0;
      const form = editor?.closest('form');
      const container = composerContainer(editor);
      if (form?.contains(input)) score += 220;
      else if (container?.contains(input)) score += 160;
      if (!accept || accept.includes('image') || accept.includes('gif')) score += 45;
      if (input.multiple) score += 18;
      if (/upload|attach|file/.test(inputHint(input))) score += 28;
      return score;
    }

    function makeTransfer(file) {
      if (typeof DataTransfer !== 'function') return null;
      try {
        const transfer = new DataTransfer();
        transfer.items.add(file);
        return transfer;
      } catch {
        return null;
      }
    }

    function attachThroughFileInput(file, editor) {
      const inputs = [...document.querySelectorAll('input[type="file"]')]
        .map(input => ({ input, score: uploadInputScore(input, editor) }))
        .filter(candidate => Number.isFinite(candidate.score) && candidate.score >= 0)
        .sort((a, b) => b.score - a.score);

      for (const { input } of inputs) {
        const transfer = makeTransfer(file);
        if (!transfer) return false;
        try {
          input.files = transfer.files;
        } catch {
          continue;
        }
        if (!input.files?.length) continue;
        input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
        return true;
      }
      return false;
    }

    function attachThroughDrop(file, editor) {
      const target = composerContainer(editor) || editor;
      if (!(target instanceof Element) || typeof DragEvent !== 'function') return false;
      const transfer = makeTransfer(file);
      if (!transfer) return false;

      try {
        for (const type of ['dragenter', 'dragover', 'drop']) {
          target.dispatchEvent(new DragEvent(type, {
            bubbles: true,
            cancelable: true,
            composed: true,
            dataTransfer: transfer
          }));
        }
        return true;
      } catch {
        return false;
      }
    }

    function attachGifToComposer(blob, filename) {
      const editor = findComposerEditor();
      if (!editor) throw new Error('Open a Discord channel with a message box before converting.');
      if (typeof File !== 'function') throw new Error('This WebKit build cannot create a local GIF attachment.');

      const file = new File([blob], filename, { type: 'image/gif', lastModified: Date.now() });
      if (attachThroughFileInput(file, editor)) return 'file-input';
      if (attachThroughDrop(file, editor)) return 'drop';
      throw new Error('Discord did not expose an attachment target for this channel.');
    }

    async function decodeImageFile(file) {
      if (typeof createImageBitmap === 'function') {
        try {
          const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
          return {
            source: bitmap,
            width: bitmap.width,
            height: bitmap.height,
            close: () => bitmap.close?.()
          };
        } catch {
          try {
            const bitmap = await createImageBitmap(file);
            return {
              source: bitmap,
              width: bitmap.width,
              height: bitmap.height,
              close: () => bitmap.close?.()
            };
          } catch {}
        }
      }

      const url = URL.createObjectURL(file);
      try {
        const image = new Image();
        image.decoding = 'async';
        image.src = url;
        await image.decode();
        return {
          source: image,
          width: image.naturalWidth,
          height: image.naturalHeight,
          close: () => {}
        };
      } finally {
        URL.revokeObjectURL(url);
      }
    }

    function targetGifSize(width, height) {
      const MAX_EDGE = 1600;
      const MAX_PIXELS = 1800000;
      const edgeScale = Math.min(1, MAX_EDGE / width, MAX_EDGE / height);
      const pixelScale = Math.min(1, Math.sqrt(MAX_PIXELS / (width * height)));
      const scale = Math.min(edgeScale, pixelScale);
      return {
        width: Math.max(1, Math.round(width * scale)),
        height: Math.max(1, Math.round(height * scale)),
        scaled: scale < 0.999
      };
    }

    function canvasGifBlob(canvas) {
      if (typeof canvas.toBlob !== 'function') return Promise.resolve(null);
      return new Promise(resolve => {
        canvas.toBlob(blob => {
          resolve(blob?.type === 'image/gif' && blob.size > 20 ? blob : null);
        }, 'image/gif');
      });
    }

    function quantizeForGif(imageData) {
      const rgba = imageData.data;
      const pixelCount = imageData.width * imageData.height;
      const histogram = new Uint32Array(32768);
      let hasTransparency = false;

      for (let offset = 0; offset < rgba.length; offset += 4) {
        if (rgba[offset + 3] < 128) {
          hasTransparency = true;
          continue;
        }
        const bin = ((rgba[offset] >> 3) << 10) | ((rgba[offset + 1] >> 3) << 5) | (rgba[offset + 2] >> 3);
        histogram[bin] += 1;
      }

      const used = [];
      for (let bin = 0; bin < histogram.length; bin += 1) {
        if (histogram[bin]) used.push(bin);
      }

      const paletteOffset = hasTransparency ? 1 : 0;
      const paletteLimit = 256 - paletteOffset;
      let selected;
      if (used.length <= paletteLimit) {
        selected = used;
      } else {
        used.sort((a, b) => histogram[b] - histogram[a]);
        selected = used.slice(0, paletteLimit);
      }
      if (!selected.length && !hasTransparency) selected = [0];

      const palette = new Uint8Array(256 * 3);
      const selectedR = new Uint8Array(selected.length);
      const selectedG = new Uint8Array(selected.length);
      const selectedB = new Uint8Array(selected.length);
      const mapping = new Int16Array(32768);
      mapping.fill(-1);

      for (let i = 0; i < selected.length; i += 1) {
        const bin = selected[i];
        const r5 = (bin >> 10) & 31;
        const g5 = (bin >> 5) & 31;
        const b5 = bin & 31;
        selectedR[i] = r5;
        selectedG[i] = g5;
        selectedB[i] = b5;
        const index = i + paletteOffset;
        const base = index * 3;
        palette[base] = Math.round(r5 * 255 / 31);
        palette[base + 1] = Math.round(g5 * 255 / 31);
        palette[base + 2] = Math.round(b5 * 255 / 31);
        mapping[bin] = index;
      }

      if (used.length > selected.length) {
        const selectedSet = new Set(selected);
        for (const bin of used) {
          if (selectedSet.has(bin)) continue;
          const r = (bin >> 10) & 31;
          const g = (bin >> 5) & 31;
          const b = bin & 31;
          let best = 0;
          let bestDistance = Infinity;
          for (let i = 0; i < selected.length; i += 1) {
            const dr = r - selectedR[i];
            const dg = g - selectedG[i];
            const db = b - selectedB[i];
            const distance = dr * dr * 2 + dg * dg * 4 + db * db;
            if (distance < bestDistance) {
              bestDistance = distance;
              best = i;
              if (distance === 0) break;
            }
          }
          mapping[bin] = best + paletteOffset;
        }
      }

      const indices = new Uint8Array(pixelCount);
      for (let pixel = 0, offset = 0; pixel < pixelCount; pixel += 1, offset += 4) {
        if (hasTransparency && rgba[offset + 3] < 128) {
          indices[pixel] = 0;
          continue;
        }
        const bin = ((rgba[offset] >> 3) << 10) | ((rgba[offset + 1] >> 3) << 5) | (rgba[offset + 2] >> 3);
        const mapped = mapping[bin];
        indices[pixel] = mapped >= 0 ? mapped : paletteOffset;
      }

      return { palette, indices, hasTransparency };
    }

    function createByteWriter() {
      const chunks = [];
      let buffer = new Uint8Array(65536);
      let offset = 0;

      function flush() {
        if (!offset) return;
        chunks.push(buffer.slice(0, offset));
        buffer = new Uint8Array(65536);
        offset = 0;
      }

      function byte(value) {
        if (offset === buffer.length) flush();
        buffer[offset++] = value & 255;
      }

      function bytes(values) {
        let start = 0;
        while (start < values.length) {
          if (offset === buffer.length) flush();
          const count = Math.min(buffer.length - offset, values.length - start);
          buffer.set(values.subarray ? values.subarray(start, start + count) : values.slice(start, start + count), offset);
          offset += count;
          start += count;
        }
      }

      function u16(value) {
        byte(value);
        byte(value >> 8);
      }

      return {
        byte,
        bytes,
        u16,
        blob(type) {
          flush();
          return new Blob(chunks, { type });
        }
      };
    }

    function writeGifLzw(writer, indices, minCodeSize = 8) {
      writer.byte(minCodeSize);
      const block = new Uint8Array(255);
      let blockLength = 0;
      let bitBuffer = 0;
      let bitCount = 0;

      function flushBlock() {
        if (!blockLength) return;
        writer.byte(blockLength);
        writer.bytes(block.subarray(0, blockLength));
        blockLength = 0;
      }

      function outputByte(value) {
        block[blockLength++] = value & 255;
        if (blockLength === 255) flushBlock();
      }

      function writeCode(code, size) {
        bitBuffer |= code << bitCount;
        bitCount += size;
        while (bitCount >= 8) {
          outputByte(bitBuffer & 255);
          bitBuffer >>>= 8;
          bitCount -= 8;
        }
      }

      const clearCode = 1 << minCodeSize;
      const endCode = clearCode + 1;
      let nextCode = endCode + 1;
      let codeSize = minCodeSize + 1;
      const dictionary = new Map();

      writeCode(clearCode, codeSize);
      if (indices.length) {
        let prefix = indices[0];
        for (let i = 1; i < indices.length; i += 1) {
          const symbol = indices[i];
          const key = (prefix << 8) | symbol;
          const found = dictionary.get(key);
          if (found !== undefined) {
            prefix = found;
            continue;
          }

          writeCode(prefix, codeSize);
          if (nextCode < 4096) {
            dictionary.set(key, nextCode++);
            if (nextCode > (1 << codeSize) && codeSize < 12) codeSize += 1;
          } else {
            writeCode(clearCode, codeSize);
            dictionary.clear();
            nextCode = endCode + 1;
            codeSize = minCodeSize + 1;
          }
          prefix = symbol;
        }
        writeCode(prefix, codeSize);
      }
      writeCode(endCode, codeSize);

      if (bitCount > 0) outputByte(bitBuffer & 255);
      flushBlock();
      writer.byte(0);
    }

    function encodeStaticGif(width, height, palette, indices, hasTransparency) {
      const writer = createByteWriter();
      writer.bytes(new TextEncoder().encode('GIF89a'));
      writer.u16(width);
      writer.u16(height);
      writer.byte(0xF7); // global 256-color table, 8-bit color resolution
      writer.byte(0);
      writer.byte(0);
      writer.bytes(palette);

      writer.byte(0x21);
      writer.byte(0xF9);
      writer.byte(0x04);
      writer.byte(hasTransparency ? 0x01 : 0x00);
      writer.u16(0);
      writer.byte(0);
      writer.byte(0);

      writer.byte(0x2C);
      writer.u16(0);
      writer.u16(0);
      writer.u16(width);
      writer.u16(height);
      writer.byte(0x00);
      writeGifLzw(writer, indices, 8);
      writer.byte(0x3B);
      return writer.blob('image/gif');
    }

    async function convertImageToGif(file) {
      if (!file?.type?.startsWith('image/')) throw new Error('Choose an image file.');
      if (file.size > 40 * 1024 * 1024) throw new Error('That image is too large. Choose one under 40 MB.');

      const decoded = await decodeImageFile(file);
      try {
        if (!decoded.width || !decoded.height) throw new Error('The image has no usable dimensions.');
        const target = targetGifSize(decoded.width, decoded.height);
        const canvas = document.createElement('canvas');
        canvas.width = target.width;
        canvas.height = target.height;
        const context = canvas.getContext('2d', { alpha: true, willReadFrequently: true });
        if (!context) throw new Error('Noko-Chat could not create an image canvas.');
        context.imageSmoothingEnabled = true;
        context.imageSmoothingQuality = 'high';
        context.clearRect(0, 0, target.width, target.height);
        context.drawImage(decoded.source, 0, 0, target.width, target.height);

        const nativeGif = await canvasGifBlob(canvas);
        if (nativeGif) return { blob: nativeGif, ...target };

        // Yield once before the JS fallback so the picker can repaint its status.
        await new Promise(resolve => requestAnimationFrame(() => resolve()));
        const imageData = context.getImageData(0, 0, target.width, target.height);
        const quantized = quantizeForGif(imageData);
        const blob = encodeStaticGif(target.width, target.height, quantized.palette, quantized.indices, quantized.hasTransparency);
        return { blob, ...target };
      } finally {
        decoded.close?.();
      }
    }

    async function handleGifFile(file) {
      if (!file || converterBusy) return;
      converterBusy = true;
      showGifToast('Converting image to GIF…', 'info', 0);
      try {
        const result = await convertImageToGif(file);
        if (disposed) return;
        const filename = safeGifName(file.name);
        attachGifToComposer(result.blob, filename);
        const sizeKiB = Math.max(1, Math.round(result.blob.size / 1024));
        const resized = result.scaled ? ' · resized for efficiency' : '';
        showGifToast(`${filename} attached · ${result.width}×${result.height} · ${sizeKiB} KB${resized}`, 'success', 3600);
      } catch (error) {
        if (!disposed) showGifToast(error?.message || 'Could not convert that image.', 'error', 4200);
      } finally {
        converterBusy = false;
      }
    }

    const launcher = document.createElement('button');
    launcher.id = 'noko-chat-launcher';
    launcher.type = 'button';
    launcher.setAttribute('aria-label', 'Noko-Chat settings');
    launcher.setAttribute('title', 'Noko-Chat');
    launcher.innerHTML = '<span class="noko-chat-mark" aria-hidden="true"><span class="noko-chat-letter">N</span><span class="noko-chat-dots"><span class="noko-chat-dot"></span><span class="noko-chat-dot"></span></span></span>';

    function visible(element) {
      if (!(element instanceof Element) || !element.isConnected) return false;
      const computed = getComputedStyle(element);
      return computed.display !== 'none' &&
        computed.visibility !== 'hidden' &&
        element.getClientRects().length > 0;
    }

    function findComposer() {
      const areas = document.querySelectorAll(':is([class^="channelTextArea_"], [class*=" channelTextArea_"])');
      for (const area of areas) {
        if (visible(area)) return area;
      }
      return null;
    }

    function findComposerActions(composer) {
      if (!(composer instanceof Element)) return null;

      // Prefer Discord's dedicated composer action row.
      const rows = composer.querySelectorAll(':is([class^="buttons_"], [class*=" buttons_"])');
      for (const row of rows) {
        if (visible(row) && row.querySelector(':is(button,[role="button"])')) return row;
      }

      // Conservative fallback: use the nearest flex/grid parent of a known picker.
      const known = composer.querySelector(
        ':is(button,[role="button"])[aria-label*="emoji" i], ' +
        ':is(button,[role="button"])[aria-label*="GIF" i], ' +
        ':is(button,[role="button"])[aria-label*="sticker" i]'
      );
      if (!known) return null;

      let parent = known.parentElement;
      for (let depth = 0; parent && parent !== composer && depth < 4; depth += 1, parent = parent.parentElement) {
        const computed = getComputedStyle(parent);
        if (/flex|grid/.test(computed.display)) return parent;
      }
      return null;
    }

    function findReferenceAction(actions) {
      if (!(actions instanceof Element)) return null;
      const preferred = [
        'button[aria-label*="emoji" i]',
        'button[aria-label*="sticker" i]',
        'button[aria-label*="GIF" i]',
        '[role="button"][aria-label*="emoji" i]',
        '[role="button"][aria-label*="sticker" i]',
        '[role="button"][aria-label*="GIF" i]'
      ];
      for (const selector of preferred) {
        const candidate = actions.querySelector(selector);
        if (visible(candidate)) return candidate;
      }
      for (const candidate of actions.querySelectorAll(':is(button,[role="button"])')) {
        if (visible(candidate) && candidate !== launcher) return candidate;
      }
      return null;
    }

    function syncLauncherWithDiscord(reference) {
      // Never copy Discord's hashed action classes onto the launcher: those
      // classes may bring React-state hover backgrounds, pseudo-elements or
      // opacity rules with them. The Noko button only needs the real action row
      // for placement; its own CSS owns sizing and visual state.
      launcher.className = 'noko-chat-launcher';

      // A tiny adaptive nudge keeps the custom hit target aligned in composer
      // variants where Discord vertically offsets its native controls. We only
      // read geometry and never retain or clone the reference node.
      if (reference instanceof Element) {
        const refRect = reference.getBoundingClientRect();
        const rowRect = reference.parentElement?.getBoundingClientRect?.();
        if (rowRect && Number.isFinite(refRect.top) && Number.isFinite(rowRect.top)) {
          const refCenter = refRect.top + refRect.height / 2;
          const rowCenter = rowRect.top + rowRect.height / 2;
          const delta = Math.max(-2, Math.min(2, refCenter - rowCenter));
          launcher.style.setProperty('--noko-chat-y-offset', `${delta.toFixed(2)}px`);
          launcher.style.translate = `0 var(--noko-chat-y-offset)`;
        }
      }
    }

    function stopAttachObserver() {
      attachObserver?.disconnect();
      attachObserver = null;
      cancelAttachTimeout?.();
      cancelAttachTimeout = null;
    }

    function ensureLauncher() {
      launcherRAF = 0;
      if (launcher.isConnected) {
        stopAttachObserver();
        return true;
      }

      const composer = findComposer();
      const actions = findComposerActions(composer);
      if (!actions) return false;

      syncLauncherWithDiscord(findReferenceAction(actions));
      actions.appendChild(launcher);
      stopAttachObserver();
      return true;
    }

    function applyLauncherPreference() {
      if (!settings.showLauncher) {
        stopAttachObserver();
        if (launcherRAF) cancelAnimationFrame(launcherRAF);
        launcherRAF = 0;
        launcher.remove();
        return;
      }
      armTransientAttachmentObserver();
    }

    function scheduleLauncher() {
      if (launcher.isConnected || launcherRAF) return;
      launcherRAF = requestAnimationFrame(() => {
        launcherRAF = 0;
        ensureLauncher();
      });
    }

    function armTransientAttachmentObserver(watchForReplacement = false, lifetime = 5000) {
      const attached = ensureLauncher();
      if (attachObserver || (attached && !watchForReplacement)) return;

      const root = document.body || document.documentElement;
      attachObserver = new MutationObserver(() => {
        // While the existing composer survives, navigation mutations are free:
        // one isConnected check and no selector scan. If Discord replaces it,
        // schedule one coalesced attachment attempt on the next animation frame.
        if (!launcher.isConnected) scheduleLauncher();
      });
      attachObserver.observe(root, { childList: true, subtree: true });

      // Never watch Discord's busy DOM indefinitely.
      cancelAttachTimeout = api.timeout(() => {
        cancelAttachTimeout = null;
        stopAttachObserver();
      }, lifetime);
    }

    api.listen(launcher, 'click', event => {
      event.preventDefault();
      event.stopPropagation();
      toggleSettings();
    });

    function onKeyDown(event) {
      if (typeof event.key !== 'string') return;
      const key = event.key.toLowerCase();
      const shortcut = event.ctrlKey && event.altKey && !event.metaKey && !event.shiftKey && key === 'n';
      if (shortcut) {
        event.preventDefault();
        event.stopPropagation();
        toggleSettings();
        return;
      }
      if (event.key === 'Escape' && panelHost?.isConnected) closeSettings();
    }

    document.documentElement.appendChild(gifInput);
    api.listen(gifInput, 'change', () => {
      const file = gifInput.files?.[0] || null;
      gifInput.value = '';
      if (file) void handleGifFile(file);
    });

    loadSettings();
    // Normalize older saved settings once so removed 1.0-1.4 options disappear
    // from storage without resetting the user's still-supported preferences.
    saveSettings();
    (document.head || document.documentElement).appendChild(style);
    applySettings();
    api.listen(window, 'keydown', onKeyDown, true);

    // Initial Discord render can finish after the Tan starts, so briefly watch
    // for the composer and then disconnect completely. Launcher visibility is
    // persisted across Discord reloads; only a real Tan stop/re-enable restores
    // it as an escape hatch.
    applyLauncherPreference();

    // Watch briefly around likely Discord navigation, then disconnect again.
    // This catches composer replacement without an always-on page observer.
    api.listen(document, 'click', event => {
      const target = event.target instanceof Element ? event.target : event.target?.parentElement;
      if (!target) return;

      const converter = target.closest?.('[data-noko-chat-gif-converter="true"]');
      if (converter) {
        event.preventDefault();
        event.stopPropagation();
        if (converterBusy) {
          showGifToast('A GIF is already being converted…', 'info', 1800);
          return;
        }
        gifInput.value = '';
        gifInput.click();
        return;
      }

      const pickerControl = target.closest?.(':is(button,[role="button"],[role="tab"])');
      if (pickerControl) {
        const label = normalizedLabel(pickerControl);
        const opensPicker = label.includes('gif') || label.includes('sticker') || label.includes('emoji');
        if (opensPicker) armPickerObserver(true, 1800);
      }

      if (target.closest?.('a[href*="/channels/"], [data-list-item-id^="channels___"], [role="treeitem"]')) {
        if (settings.showLauncher) armTransientAttachmentObserver(true, 2500);
      }
    }, true);
    api.listen(window, 'popstate', () => {
      if (settings.showLauncher) armTransientAttachmentObserver(true, 2500);
    });
    api.listen(window, 'focus', () => {
      if (settings.showLauncher && !launcher.isConnected) armTransientAttachmentObserver();
      if (document.querySelector('[role="tab"]')) ensureGifConverterTab();
    });

    globalThis.NokoChat = Object.freeze({
      version: VERSION,
      openSettings,
      closeSettings,
      toggleSettings,
      getSettings: () => ({ ...settings }),
      reset: () => {
        settings = { ...DEFAULTS };
        saveSettings();
        applySettings();
        applyLauncherPreference();
      }
    });

    api.onCleanup(() => {
      restoreLauncherPreferenceAfterRealDisable();
      disposed = true;
      stopAttachObserver();
      stopPickerObserver();
      cancelGifToastTimeout?.();
      cancelGifToastTimeout = null;
      if (launcherRAF) cancelAnimationFrame(launcherRAF);
      launcherRAF = 0;
      launcher.remove();
      gifInput.remove();
      document.querySelectorAll('[data-noko-chat-gif-converter="true"]').forEach(node => node.remove());
      gifToastHost?.remove();
      gifToastHost = null;
      closeSettings();
      style.remove();
      clearRootState();
      try { delete globalThis.NokoChat; } catch {}
    });
  }
});

"""##

    private static let morganaJS = ##"""
// Morgana 1.1.0
// Bundled notification audio SHA-256: 7679719d508c10d289a008b06602830a522deb437a000c5462c43abe17111f64
// Replaces only Discord incoming message / mention pings.
(() => {
  'use strict';

  const CUSTOM_SOUND_BASE64 = "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";
  const CUSTOM_DATA_URL = 'data:audio/mpeg;base64,' + CUSTOM_SOUND_BASE64;

  // Known Discord message / mention asset hashes. These are used only as a
  // fallback for Discord builds that resolve semantic sound names to hashed
  // /assets/*.mp3 URLs before constructing the audio element.
  const KNOWN_PING_HASHES = new Set([
    '3ed22d14f3c30bc4', // message1
    '91f9f6fa8cc9ea5c', // message2
    '4f53c2f31ea0cdd8', // message3
    '3baf62fc7aebb0a3', // mention1
    'e0a0235d2fa32496', // mention2
    '260dfacf63b6cb13', // mention3
    '7abbc45d8e7b179a', // asmr_message1
    '795109c70fe6ea7b', // bit_message1
    '909464bf55b13935', // bop_message1
    '7d8709c9f90d5d1e', // ducky_message1
    'c269de500ca3cb7b', // halloween_message1
    '5aa5ffdc82cb3c74'  // lofi_message1
  ]);

  let active = true;
  let customBlobURL = null;

  function getCustomSoundURL() {
    if (customBlobURL) return customBlobURL;
    // Create the Blob lazily, at the moment Discord is actually trying to play
    // a ping. This avoids document-start WebKit timing quirks. If Blob URLs are
    // unavailable for any reason, HTMLAudioElement can still play the data URL.
    try {
      const binary = atob(CUSTOM_SOUND_BASE64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
      customBlobURL = URL.createObjectURL(new Blob([bytes], {type: 'audio/mpeg'}));
      return customBlobURL;
    } catch {
      return CUSTOM_DATA_URL;
    }
  }

  function normalizedSource(value) {
    if (typeof value !== 'string' || !value || value.length > 4096) return '';
    return value.trim().toLowerCase().split('#', 1)[0].split('?', 1)[0];
  }

  function isIncomingNotificationSource(value) {
    const src = normalizedSource(value);
    if (!src || src === normalizedSource(customBlobURL) || src.startsWith('data:audio/mpeg;base64,')) return false;

    const leaf = src.slice(src.lastIndexOf('/') + 1);
    // Covers semantic URLs such as message1.mp3, mention2.mp3 and sound-pack
    // variants such as bit_message1.mp3 without matching message_send.mp3.
    if (/^(?:[a-z0-9-]+_)*(?:message[123]|mention[123])\.(?:mp3|m4a|ogg|wav|aac)$/.test(leaf)) return true;

    // Discord commonly serves sounds as /assets/<hash>.mp3.
    const match = leaf.match(/^([a-f0-9]{16,64})\.(?:mp3|m4a|ogg|wav|aac)$/);
    if (match && KNOWN_PING_HASHES.has(match[1])) return true;
    return false;
  }

  function replaceElementSource(element) {
    if (!active || !element) return false;
    let src = '';
    try { src = element.currentSrc || element.src || element.getAttribute?.('src') || ''; } catch {}
    if (!isIncomingNotificationSource(src)) return false;
    const replacement = getCustomSoundURL();
    try {
      if (element.src !== replacement) element.src = replacement;
      return true;
    } catch { return false; }
  }

  const NativeAudio = globalThis.Audio;
  let AudioProxy = null;
  if (typeof NativeAudio === 'function') {
    AudioProxy = new Proxy(NativeAudio, {
      construct(target, args, newTarget) {
        const next = Array.from(args || []);
        if (active && isIncomingNotificationSource(next[0])) next[0] = getCustomSoundURL();
        return Reflect.construct(target, next, newTarget === AudioProxy ? target : newTarget);
      },
      apply(target, thisArg, args) {
        const next = Array.from(args || []);
        if (active && isIncomingNotificationSource(next[0])) next[0] = getCustomSoundURL();
        return Reflect.apply(target, thisArg, next);
      }
    });
    try { globalThis.Audio = AudioProxy; } catch { AudioProxy = null; }
  }

  const mediaProto = globalThis.HTMLMediaElement?.prototype;
  const originalPlay = mediaProto?.play;
  let patchedPlay = null;
  if (mediaProto && typeof originalPlay === 'function') {
    patchedPlay = function(...args) {
      if (active) {
        try { replaceElementSource(this); } catch {}
      }
      return Reflect.apply(originalPlay, this, args);
    };
    try { mediaProto.play = patchedPlay; } catch { patchedPlay = null; }
  }

  // Keep the semantic Webpack interception as a secondary path. If Discord
  // exposes message1/mention1 names before resolving their URL, this replaces
  // them even earlier; if not, the Audio/play hooks above still catch playback.
  const PATCH_MARK = Symbol.for('noko.morgana.webpack-context-patch.v2');
  const PUSH_MARK = Symbol.for('noko.morgana.webpack-push-patch.v2');
  let chunkArray = null;
  let originalPush = null;

  function isIncomingNotificationAsset(request) {
    if (typeof request !== 'string' || request.length > 256) return false;
    const clean = request.toLowerCase().split(/[?#]/, 1)[0];
    const base = clean.slice(clean.lastIndexOf('/') + 1);
    return /^(?:[a-z0-9-]+_)*(?:message[123]|mention[123])\.(?:mp3|m4a|ogg|wav|aac)$/.test(base);
  }

  function looksLikeSoundContext(factory) {
    if (typeof factory !== 'function') return false;
    let source = '';
    try { source = Function.prototype.toString.call(factory); } catch { return false; }
    return /message1\.(?:mp3|m4a|ogg|wav|aac)/i.test(source)
      || /mention[123]\.(?:mp3|m4a|ogg|wav|aac)/i.test(source);
  }

  function wrapContext(context) {
    if (typeof context !== 'function' || context[PATCH_MARK]) return context;
    const proxy = new Proxy(context, {
      apply(target, thisArg, args) {
        if (active && isIncomingNotificationAsset(args?.[0])) return getCustomSoundURL();
        return Reflect.apply(target, thisArg, args);
      }
    });
    try { Object.defineProperty(proxy, PATCH_MARK, {value: true}); } catch {}
    return proxy;
  }

  function wrapFactory(factory) {
    if (factory?.[PATCH_MARK]) return factory;
    const wrapped = function(module) {
      const result = Reflect.apply(factory, this, arguments);
      if (active && module && typeof module.exports === 'function') module.exports = wrapContext(module.exports);
      return result;
    };
    try { Object.defineProperty(wrapped, PATCH_MARK, {value: true}); } catch {}
    return wrapped;
  }

  function patchChunk(chunk) {
    if (!active || !Array.isArray(chunk) || !chunk[1] || typeof chunk[1] !== 'object') return;
    for (const id of Object.keys(chunk[1])) {
      const factory = chunk[1][id];
      if (looksLikeSoundContext(factory)) chunk[1][id] = wrapFactory(factory);
    }
  }

  function installWebpackHook() {
    const existing = globalThis.webpackChunkdiscord_app;
    chunkArray = Array.isArray(existing) ? existing : [];
    for (const chunk of chunkArray) patchChunk(chunk);
    originalPush = chunkArray.push;
    if (originalPush?.[PUSH_MARK]) return;
    const patchedPush = function(...chunks) {
      if (active) for (const chunk of chunks) patchChunk(chunk);
      return Reflect.apply(originalPush, this, chunks);
    };
    try { Object.defineProperty(patchedPush, PUSH_MARK, {value: true}); } catch {}
    chunkArray.push = patchedPush;
    globalThis.webpackChunkdiscord_app = chunkArray;
  }

  installWebpackHook();

  NokoTan.register({
    start(api) {
      api.onCleanup(() => {
        active = false;
        if (AudioProxy && globalThis.Audio === AudioProxy) {
          try { globalThis.Audio = NativeAudio; } catch {}
        }
        if (patchedPlay && mediaProto?.play === patchedPlay) {
          try { mediaProto.play = originalPlay; } catch {}
        }
        if (chunkArray && originalPush && chunkArray.push?.[PUSH_MARK]) {
          try { chunkArray.push = originalPush; } catch {}
        }
        if (customBlobURL) {
          try { URL.revokeObjectURL(customBlobURL); } catch {}
          customBlobURL = null;
        }
      });
    },
    stop() { active = false; }
  });
})();

"""##
}
