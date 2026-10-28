// NokoCord adapters, GPL-3.0-only. Upstream notices are retained in vendor/.
(() => {
  'use strict';
  const api = NokoTan;
  const KEY = Symbol.for('noko.fake-nitro.compat.v1');
  const NK_PATH = "globalThis[Symbol.for('noko.fake-nitro.compat.v1')]";
  let active = true, generation = 1, panel = null, launcher = null;
  const pending = new Set(), dialogs = new Set();
  const records = [], seenExports = new WeakSet(), queries = new Map();
  const compiledFeatures = new Set();
  let appliedLocalTheme = false, remoteAppearance = null;
  const status = new Map();

  function sourceOf(value) {
    try { return typeof value === 'function' ? Function.prototype.toString.call(value) : ''; }
    catch { return ''; }
  }
  function storeName(value) {
    try {
      if (value && typeof value.getName === 'function') return value.getName();
      return value?.constructor?.displayName || '';
    } catch { return ''; }
  }
  function candidates(value) {
    if (!value || !['object', 'function'].includes(typeof value)) return [];
    if (storeName(value)) return [value];
    const result = [value];
    for (const name of Object.keys(value).slice(0, 96)) {
      try {
        const child = value[name];
        if (child && ['object', 'function'].includes(typeof child)) result.push(child);
      } catch { /* An export can be in its temporal dead zone. */ }
    }
    return result;
  }
  function record(value) {
    if (!active || !value || !['object', 'function'].includes(typeof value) || seenExports.has(value)) return;
    seenExports.add(value);
    if (records.length < 12000) records.push(value);
  }
  function lookup(key, predicate) {
    let query = queries.get(key);
    if (!query) { query = { index: 0, value: null }; queries.set(key, query); }
    if (query.value) return query.value;
    while (query.index < records.length) {
      const value = records[query.index++];
      for (const candidate of candidates(value)) {
        try { if (predicate(candidate)) return (query.value = candidate); } catch {}
      }
    }
    return null;
  }
  const byProps = (...props) => lookup('props:' + props.join(','), value => props.every(p => p in value));
  const byCode = (...markers) => lookup('code:' + markers.join(','), value => {
    const text = sourceOf(value); return markers.every(marker => text.includes(marker));
  });
  const namedStore = name => lookup('store:' + name, value => storeName(value) === name);
  function lazy(get) {
    return new Proxy(function () {}, {
      get(_, key) {
        if (key === 'then') return undefined;
        const value = get();
        if (!value) return undefined;
        const member = Reflect.get(value, key);
        // Keep constructor/static metadata while retaining method receivers.
        return typeof member === 'function' ? new Proxy(member, {
          apply(target, _, args) { return Reflect.apply(target, value, args); }
        }) : member;
      },
      apply(_, receiver, args) {
        const value = get();
        if (typeof value !== 'function') throw new Error('Discord compatibility is not ready. Reload Discord.');
        return Reflect.apply(value, receiver, args);
      }
    });
  }
  const findByPropsLazy = (...props) => lazy(() => byProps(...props));
  const findByCodeLazy = (...markers) => lazy(() => byCode(...markers));
  const proxyLazyWebpack = get => lazy(get);
  const store = name => lazy(() => namedStore(name));
  const UserStore = store('UserStore'), ChannelStore = store('ChannelStore');
  const PermissionStore = store('PermissionStore'), EmojiStore = store('EmojiStore');
  const StickersStore = store('StickersStore'), GuildMemberStore = store('GuildMemberStore');
  const UserSettingsActionCreators = {
    PreloadedUserSettingsActionCreators: lazy(() => lookup('preloaded-settings', value => value.ProtoClass?.typeName?.endsWith('.PreloadedUserSettings')))
  };
  const FluxDispatcher = lazy(() => lookup('dispatcher', value => ['dispatch', 'subscribe', 'unsubscribe'].every(p => typeof value[p] === 'function')));
  const UploadHandler = { get promptToUpload() { return byCode('Unexpected mismatch between files and file metadata') || byProps('promptToUpload')?.promptToUpload; } };
  const DraftType = findByPropsLazy('ChannelMessage', 'SlashCommand');
  const PermissionsBits = Object.freeze({
    ADMINISTRATOR: 8n, EMBED_LINKS: 16384n, ATTACH_FILES: 32768n,
    USE_EXTERNAL_EMOJIS: 262144n, USE_EXTERNAL_STICKERS: 137438953472n
  });
  const StickerFormatType = Object.freeze({ PNG: 1, APNG: 2, LOTTIE: 3, GIF: 4 });
  class Logger { error() { status.set('compatibility', 'A Discord feature is unavailable in this version.'); } }
  const Devs = new Proxy({}, { get: (_, name) => String(name) });
  const OptionType = Object.freeze({ BOOLEAN: 'boolean', SELECT: 'select', STRING: 'string' });
  const definePlugin = value => value;
  const STORAGE = 'noko.fake-nitro.settings.v1';
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(STORAGE) || '{}'); } catch {}
  function definePluginSettings(definitions) {
    const values = {};
    for (const [key, definition] of Object.entries(definitions)) {
      const candidate = saved?.[key];
      values[key] = typeof candidate === typeof definition.default ? candidate : definition.default;
    }
    values.enableThemes = saved?.enableThemes !== false;
    values.enableAppIcons = saved?.enableAppIcons !== false;
    for (const key of ['emojiSize', 'stickerSize']) {
      if (![16, 32, 48, 56, 64, 96, 128, 160, 256, 512, 1024].includes(values[key])) values[key] = key === 'emojiSize' ? 48 : 160;
    }
    values.hyperLinkText = String(values.hyperLinkText).slice(0, 120);
    return { store: values, use: () => values };
  }
  function persistSettings() {
    try { localStorage.setItem(STORAGE, JSON.stringify(settings.store)); } catch {}
  }
  function currentChannelIs(id) {
    const selected = namedStore('SelectedChannelStore')?.getChannelId?.();
    return selected ? selected === id : location.pathname.split('/').at(-1) === id;
  }
  function hasStore(name, methods) {
    const value = namedStore(name);
    return !!value && methods.every(method => typeof value[method] === 'function');
  }
  function ready(feature) {
    if (!active) return false;
    if (feature === 'appIcons') return settings.store.enableAppIcons && compiledFeatures.has('appIconEligibility') && compiledFeatures.has('appIconRender');
    if (feature === 'stream') return settings.store.enableStreamQualityBypass && compiledFeatures.has('eligibility') && compiledFeatures.has('qualityPicker');
    if (feature === 'themes') return settings.store.enableThemes && compiledFeatures.has('eligibility') && compiledFeatures.has('themeSelect') && compiledFeatures.has('themeIncoming')
      && !!UserSettingsActionCreators.PreloadedUserSettingsActionCreators?.ProtoClass && typeof FluxDispatcher.dispatch === 'function'
      && typeof AppearanceSettingsActionCreators.create === 'function' && typeof ClientThemeSettingsActionsCreators.create === 'function';
    if (!compiledFeatures.has('send') || !hasStore('UserStore', ['getCurrentUser']) || !hasStore('ChannelStore', ['getChannel'])
      || !hasStore('PermissionStore', ['can'])) return false;
    if (feature === 'emoji') return settings.store.enableEmojiBypass && hasStore('EmojiStore', ['getCustomEmojiById']) && compiledFeatures.has('emojiPicker');
    return feature === 'sticker' && settings.store.enableStickerBypass && hasStore('StickersStore', ['getStickerById']) && compiledFeatures.has('eligibility') && compiledFeatures.has('stickerPicker');
  }
  function validMedia(raw) {
    try {
      const url = new URL(raw);
      if (url.protocol !== 'https:' || url.username || url.password || url.port || url.hash
        || !['cdn.discordapp.com', 'media.discordapp.net'].includes(url.hostname)) return null;
      return /^\/(?:emojis|stickers)\/\d{6,24}\.(?:png|webp|gif)$/.test(url.pathname) ? url : null;
    } catch { return null; }
  }
  async function confirmLinkOnly() {
    return showDialog('This channel cannot embed links', 'The emoji or sticker will appear as a link. Send it anyway?', 'Send link');
  }
  function showDialog(title, explanation, action = 'OK', cancellable = true) {
    if (!active) return Promise.resolve(false);
    return new Promise(resolve => {
      const host = document.createElement('div'), shadow = host.attachShadow({ mode: 'closed' });
      host.setAttribute('data-noko-fake-nitro-dialog', '');
      const style = document.createElement('style');
      style.textContent = ':host{position:fixed;inset:0;z-index:2147483646;display:grid;place-items:center;background:#0008;font:14px system-ui;color:var(--text-normal,#eee)}section{width:min(420px,80vw);padding:24px;font:14px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;border:1px solid #ffffff25;border-radius:18px;background:var(--background-secondary,#26262d);box-shadow:0 16px 60px #0008}h2{font-size:18px;margin:0 0 12px}p{line-height:1.5}footer{display:flex;justify-content:flex-end;gap:10px;margin-top:22px}button{border:0;border-radius:9px;padding:9px 14px;background:#5865f2;color:white;cursor:pointer}button.cancel{background:#ffffff15}';
      const section = document.createElement('section'); section.setAttribute('role', 'dialog'); section.setAttribute('aria-modal', 'true');
      const heading = document.createElement('h2'); heading.textContent = title; heading.id = 'title'; section.setAttribute('aria-labelledby', 'title');
      const p = document.createElement('p'); p.textContent = explanation;
      const footer = document.createElement('footer');
      const previous = document.activeElement;
      const finish = value => { if (!dialogs.delete(cancel)) return; host.remove(); previous?.focus?.({ preventScroll: true }); resolve(value); };
      const cancel = () => finish(false); dialogs.add(cancel);
      if (cancellable) { const button = document.createElement('button'); button.className = 'cancel'; button.textContent = 'Cancel'; button.onclick = cancel; footer.append(button); }
      const button = document.createElement('button'); button.textContent = action; button.onclick = () => finish(true); footer.append(button);
      section.append(heading, p, footer); shadow.append(style, section); document.documentElement.append(host); button.focus();
      host.addEventListener('keydown', event => {
        if (event.key === 'Escape') { event.preventDefault(); cancel(); }
        if (event.key === 'Tab') { const buttons = [...footer.querySelectorAll('button')]; const at = buttons.indexOf(shadow.activeElement); event.preventDefault(); buttons[(at + (event.shiftKey ? buttons.length - 1 : 1)) % buttons.length].focus(); }
      });
    });
  }
  const control = { active: true, can: ready };
  globalThis[KEY]?.stop?.();
  Object.defineProperty(globalThis, KEY, { value: control, configurable: true });
  /* NOKO_FAKE_NITRO_CORE */
  /* NOKO_FAKE_NITRO_CODEC */
  /* NOKO_FAKE_NITRO_ADAPTER */
})();
