  const customToken = /^<(a?):([^\s:<>]{1,128}):(\d{6,24})>/u;
  const escapeLabel = value => String(value).replace(/[\\\[\]()]/g, '\\$&').replace(/[\r\n]/g, ' ');
  function mediaLink(url, name) {
    const valid = validMedia(url); if (!valid) throw new Error('Discord returned an unsupported media address.');
    valid.searchParams.set('name', String(name).slice(0, 128)); valid.searchParams.set('lossless', 'true');
    const text = escapeLabel(settings.store.hyperLinkText.replaceAll('{{NAME}}', String(name)));
    return settings.store.useHyperLinks ? `[${text || escapeLabel(name)}](${valid.href})` : valid.href;
  }
  function rewriteTokens(content, resolve) {
    let output = '', i = 0, changed = false;
    while (i < content.length) {
      if (content[i] === '\\') { output += content.slice(i, i + 2); i += 2; continue; }
      if (content[i] === '`') {
        let end = i; while (content[end] === '`') end++;
        const marker = content.slice(i, end), close = content.indexOf(marker, end);
        if (close < 0) { output += content.slice(i); break; }
        output += content.slice(i, close + marker.length); i = close + marker.length; continue;
      }
      if (content[i] === '[' || content.slice(i, i + 2) === '![') {
        const middle = content.indexOf('](', i);
        if (middle >= 0 && !content.slice(i, middle).includes('\n')) {
          let end = middle + 2, depth = 1;
          for (; end < content.length && depth; end++) {
            if (content[end] === '\\') { end++; continue; }
            if (content[end] === '(') depth++; else if (content[end] === ')') depth--;
            if (depth > 8) break;
          }
          if (!depth) { output += content.slice(i, end); i = end; continue; }
        }
      }
      const url = content.slice(i).match(/^https?:\/\/[^\s<>]+/);
      if (url) { output += url[0]; i += url[0].length; continue; }
      const token = content.slice(i).match(customToken);
      if (token) {
        const replacement = resolve(token);
        if (replacement) {
          output += getWordBoundary(content, i - 1) + replacement + getWordBoundary(content, i + token[0].length);
          changed = true;
        } else output += token[0];
        i += token[0].length; continue;
      }
      output += content[i++];
    }
    return { content: output, changed };
  }
  function canUseEmoji(emoji, channelId) {
    if (emoji.type === 0) return true;
    if (emoji.available === false) return false;
    const channel = ChannelStore.getChannel(channelId);
    if (!channel) return true; // Unknown context must preserve Discord's original path.
    const guild = channel.guild_id;
    try { if (isUnusableRoleSubscriptionEmoji(emoji, guild, true)) return false; } catch {}
    const roles = emoji.guildId ? GuildMemberStore.getSelfMember?.(emoji.guildId)?.roles || [] : [];
    const managed = emoji.managed && Array.isArray(emoji.roles) && emoji.roles.some(role => roles.includes(role));
    const premium = (UserStore.getCurrentUser()?.premiumType ?? 0) > 0;
    return premium || managed ? emoji.guildId === guild || hasExternalEmojiPerms(channelId) : !emoji.animated && emoji.guildId === guild;
  }
  const sendFlights = new WeakSet();
  async function beforeMessage(channelId, message, options = {}, editing = false) {
    if (!active || !compiledFeatures.has(editing ? 'edit' : 'send') || !message || typeof message.content !== 'string') return false;
    if (!options || typeof options !== 'object' || message.content.length > 32000) return false;
    if (sendFlights.has(message)) return true;
    const lease = generation, original = message.content, ids = Array.isArray(options.stickerIds) ? [...options.stickerIds] : [];
    const originalIds = JSON.stringify(ids); sendFlights.add(message);
    try {
      let content = original, changed = false, remainingIds = ids, animated = null;
      if (!editing && ready('sticker') && ids.length) {
        const sticker = StickersStore.getStickerById(ids[0]);
        const channel = ChannelStore.getChannel(channelId);
        if (sticker && channel && !('pack_id' in sticker)) {
          const native = sticker.available !== false && (sticker.guild_id === channel.guild_id
            || (UserStore.getCurrentUser()?.premiumType ?? 0) > 1 && hasExternalStickerPerms(channelId));
          if (!native) {
            const url = upstream.getStickerLink(sticker);
            if (sticker.format_type === StickerFormatType.APNG) animated = { sticker, url };
            else { content += getWordBoundary(content, content.length - 1) + mediaLink(url, sticker.name); remainingIds = ids.slice(1); changed = true; }
          }
        }
      }
      if (ready('emoji')) {
        const parsed = editing ? null : message.validNonShortcutEmojis;
        if (!editing && !Array.isArray(parsed)) {
          compiledFeatures.delete('send'); status.set('emoji', 'Discord changed its message format. Normal sending is preserved.'); return false;
        }
        const available = parsed ? new Map(parsed.filter(e => e?.id).map(e => [String(e.id), e])) : null;
        const rewritten = rewriteTokens(content, match => {
          const emoji = available ? available.get(match[3]) : EmojiStore.getCustomEmojiById(match[3]);
          if (!emoji || canUseEmoji(emoji, channelId)) return null;
          const ext = emoji.animated ? 'gif' : 'png';
          const url = new URL(`https://cdn.discordapp.com/emojis/${match[3]}.${ext}`); url.searchParams.set('size', settings.store.emojiSize);
          return mediaLink(url.href, emoji.name || match[2]);
        });
        content = rewritten.content; changed ||= rewritten.changed;
      }
      if (animated) {
        if (!hasAttachmentPerms(channelId) || typeof UploadHandler.promptToUpload !== 'function' || DraftType.ChannelMessage == null) {
          await showDialog('Animated sticker unavailable', 'This channel needs attachment permission and Discord’s upload dialog to send the converted GIF.', 'Keep draft', false); return true;
        }
        const file = await animatedStickerFile(animated.url, String(animated.sticker.id), lease);
        if (!active || generation !== lease || !currentChannelIs(channelId) || message.content !== original) return true;
        // Discord owns the upload preview and the final send action. Never use
        // authenticated HTTP or automatically submit the generated attachment.
        UploadHandler.promptToUpload([file], ChannelStore.getChannel(channelId), DraftType.ChannelMessage);
        return true;
      }
      if (!changed) return false;
      if (content.length > ((UserStore.getCurrentUser()?.premiumType ?? 0) === 2 ? 4000 : 2000)) {
        await showDialog('Converted message is too long', 'Emoji and sticker links count toward Discord’s message limit. Shorten the message or send the item separately.', 'Keep draft', false); return true;
      }
      if (!settings.store.disableEmbedPermissionCheck && !hasEmbedPerms(channelId) && !await confirmLinkOnly()) return true;
      if (!active || generation !== lease || !currentChannelIs(channelId) || message.content !== original || (!editing && JSON.stringify(options.stickerIds || []) !== originalIds)) return true;
      // Commit atomically after all work and confirmations. Replies, mentions,
      // attachments, TTS and all unrelated parsed-message fields stay intact.
      message.content = content;
      if (!editing && JSON.stringify(remainingIds) !== originalIds) options.stickerIds = remainingIds;
      return false;
    } catch (error) {
      const cancelled = error?.name === 'AbortError' || /cancelled/i.test(error?.message || '');
      if (!cancelled && active && generation === lease) await showDialog('Could not prepare FakeNitro media', 'Your draft was kept. Try again, choose a smaller sticker size, or send without this item.', 'Keep draft', false);
      return true;
    } finally { sendFlights.delete(message); }
  }
  control.preSend = (channelId, message, options) => beforeMessage(channelId, message, options, false);
  control.preEdit = (channelId, messageId, message) => beforeMessage(channelId, message, {}, true);

  const isOfficialLink = value => {
    if (typeof value !== 'string') return false;
    const markdown = value.match(/^\[[^\]\n]*\]\((https:\/\/[^)\s]+)\)$/);
    return !!validMedia(markdown ? markdown[1] : value);
  };
  function gifStickerId(url) {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.port || parsed.hash
        || !['cdn.discordapp.com', 'media.discordapp.net'].includes(parsed.hostname)) return null;
      const match = parsed.pathname.match(/^\/attachments\/\d{6,24}\/\d{6,24}\/(\d{6,24})\.gif$/);
      return match && StickersStore.getStickerById(match[1]) ? match[1] : null;
    } catch { return null; }
  }
  control.transformAst = ast => {
    if (!active || !Array.isArray(ast)) return ast;
    // Upstream rendering uses Discord's own emoji/sticker renderers. Restrict
    // its input to official CDN links; preserve code, spoilers and other AST.
    return upstream.transformAst(ast.map(node => node?.type === 'link' && !validMedia(node.target) ? { ...node, type: '__noko_preserved_link' } : node))
      .map(node => node?.type === '__noko_preserved_link' ? { ...node, type: 'link' } : node);
  };
  control.patchFakeNitroStickers = (stickers, message) => {
    if (!active || !Array.isArray(stickers) || !settings.store.transformStickers || !compiledFeatures.has('renderAccessories') || !message || typeof message.content !== 'string') return stickers;
    const attachments = Array.isArray(message.attachments) ? message.attachments.filter(a => a?.content_type === 'image/gif' && gifStickerId(a.url)) : [];
    const content = message.content.split(/\s+/).filter(isOfficialLink).join(' ');
    if (!settings.store.transformCompoundSentence && !isOfficialLink(message.content.trim()) && !(attachments.length && !message.content.trim())) return stickers;
    return upstream.patchFakeNitroStickers([...stickers], { ...message, content, attachments });
  };
  control.shouldIgnoreEmbed = (embed, message) => active && isOfficialLink(embed?.url || embed?.image?.url)
    ? upstream.shouldIgnoreEmbed(embed, message) : false;
  // Only the upstream numeric filename convention AND a known sticker can
  // identify converted GIFs; unrelated attachments always remain visible.
  control.filterAttachments = (attachments, message) => {
    if (!active || !Array.isArray(attachments) || !settings.store.transformStickers || !compiledFeatures.has('renderAccessories')
      || typeof message?.content !== 'string' || (!settings.store.transformCompoundSentence && message.content.trim())) return attachments;
    return attachments.filter(a => a?.content_type !== 'image/gif' || !gifStickerId(a.url));
  };
  control.addFakeNotice = (type, node, fake) => active ? upstream.addFakeNotice(type, node, fake) : node;

  function appearanceCreator() { return AppearanceSettingsActionCreators; }
  function copyAppearance(value) {
    if (!value) return null;
    const creator = appearanceCreator();
    return typeof creator.toBinary === 'function' && typeof creator.fromBinary === 'function'
      ? creator.fromBinary(creator.toBinary(value), BINARY_READ_OPTIONS) : creator.create({ ...value });
  }
  let localTheme = null;
  try {
    const value = JSON.parse(localStorage.getItem('noko.fake-nitro.theme.v1') || 'null');
    if (Number.isInteger(value?.preset) && value.preset >= 0 && value.preset <= 10000 && Number.isInteger(value.theme) && value.theme >= 0 && value.theme <= 20) localTheme = value;
  } catch {}
  function themeAppearance(theme, preset, baseline) {
    const appearance = copyAppearance(baseline) || AppearanceSettingsActionCreators.create();
    appearance.theme = theme;
    const client = ClientThemeSettingsActionsCreators.create({ backgroundGradientPresetId: { value: preset } });
    appearance.clientThemeSettings = client; return appearance;
  }
  function applyTheme(theme, preset) {
    if (!ready('themes') || (UserStore.getCurrentUser()?.premiumType ?? 0) === 2) return false;
    const creators = PreloadedUserSettingsActionCreators;
    const baseline = creators.getCurrentValue()?.appearance;
    if (!appliedLocalTheme) remoteAppearance = copyAppearance(baseline);
    const proto = creators.ProtoClass.create(); proto.appearance = themeAppearance(theme, preset, baseline);
    FluxDispatcher.dispatch({ type: 'USER_SETTINGS_PROTO_UPDATE', local: true, partial: true, settings: { type: 1, proto } });
    appliedLocalTheme = true; status.delete('themes'); return true;
  }
  control.handleThemeReset = preset => {
    if (!active || preset != null) return;
    // A standard-theme choice supersedes the saved local gradient. Clear it
    // before Discord dispatches or syncs, so neither an echo nor reload can
    // put the gradient back. This also covers appearance sync being disabled.
    const hadOverride = !!localTheme || appliedLocalTheme;
    localTheme = null;
    try { localStorage.removeItem('noko.fake-nitro.theme.v1'); } catch {}
    restoreRemoteTheme();
    if (hadOverride) {
      // With appearance sync off, Discord reads this local settings overlay
      // ahead of its proto. updateTheme() only writes the base theme there.
      try {
        FluxDispatcher.dispatch({ type: 'SELECTIVELY_SYNCED_USER_SETTINGS_UPDATE', changes: {
          appearance: { settings: { clientThemeSettings: { backgroundGradientPresetId: null, customUserThemeSettings: undefined } } }
        } });
      } catch { status.set('themes', 'This Discord version cannot clear its local theme overlay.'); return; }
    }
    status.delete('themes');
  };
  control.handleGradientThemeSelect = (preset, theme, original) => {
    if (preset == null) { control.handleThemeReset(preset); return original(); }
    if (!ready('themes') || (UserStore.getCurrentUser()?.premiumType ?? 0) === 2) return original();
    try {
      if (!applyTheme(theme, preset)) return original();
      localTheme = { preset, theme }; localStorage.setItem('noko.fake-nitro.theme.v1', JSON.stringify(localTheme));
    } catch { status.set('themes', 'This Discord version cannot apply local themes.'); }
  };
  control.handleProtoChange = (proto, user) => {
    if (!ready('themes') || !localTheme || !proto || typeof proto !== 'object' || (user?.premium_type ?? UserStore.getCurrentUser()?.premiumType ?? 0) === 2) return;
    try {
      remoteAppearance = copyAppearance(proto.appearance);
      proto.appearance = themeAppearance(localTheme.theme, localTheme.preset, proto.appearance); appliedLocalTheme = true; status.delete('themes');
    } catch { status.set('themes', 'This Discord version cannot restore local themes.'); }
  };

  function canonicalMatch(value) {
    const isString = typeof value === 'string';
    let text = isString ? value : value.source;
    text = text.replaceAll(/#\{intl::([\w$+/]*)(?:::(\w+))?\}/g, (_, key, modifier) => {
      const hashed = modifier === 'raw' ? key : INTL_KEYS[key];
      if (!hashed) throw new Error('Unknown message key.');
      const special = !Number.isNaN(Number(hashed[0])) || hashed.includes('+') || hashed.includes('/');
      return special ? (isString ? `["${hashed}"]` : `(?:\\["${hashed.replaceAll('+', '\\+')}"\\])`) : (isString ? '.' + hashed : '(?:\\.' + hashed + ')');
    });
    if (isString) return text;
    text = text.replaceAll(/(\\*)\\i/g, (match, leading) => leading.length % 2 === 0 ? leading + '(?:[A-Za-z_$][\\w$]*)' : match.slice(1));
    return new RegExp(text, value.flags);
  }
  function patchList() {
    const list = [];
    for (const patch of upstream.patches) {
      const marker = patch.find;
      const replacements = (Array.isArray(patch.replacement) ? patch.replacement : [patch.replacement]).map(value => ({ ...value }));
      let feature = 'render';
      if (marker === 'canUseCustomStickersEverywhere:') {
        for (const replacement of replacements) {
          const code = replacement.match.source;
          if (code.includes('canUsePremiumAppIcons')) { replacement.skip = true; continue; }
          const option = code.includes('Sticker') ? 'sticker' : code.includes('ClientThemes') ? 'themes' : 'stream';
          replacement.replace = `if(${NK_PATH}.can('${option}'))return true;`;
        }
        feature = 'eligibility';
      } else if (marker === 'getCurrentDesktopIcon(),') {
        // Discord calls its persisted in-app home logo a desktop icon. This
        // gate is separate from NokoCord's native macOS application icon.
        replacements[0].replace = match => `(${match}||${NK_PATH}.can('appIcons'))`;
        feature = 'appIconRender';
      } else if (marker === '.getByName("fork_and_knife")') {
        replacements[0].match = /(\i(?:\.\i)*)\.CHAT/;
        replacements[0].replace = (_, owner) => `(${NK_PATH}.can('emoji')?${owner}.STATUS:${owner}.CHAT)`; feature = 'voicePicker';
      } else if (marker === '.GUILD_SUBSCRIPTION_UNAVAILABLE;') feature = 'emojiPicker';
      else if (marker === '.getUserIsAdmin(') {
        replacements[0].replace = (_, rest, body) => `${rest},fakeNitroOriginal){if(${NK_PATH}.can('emoji')&&!fakeNitroOriginal)return false;${body}`; feature = 'roleEmoji';
      } else if (marker === '"SENDABLE"') {
        replacements[0].replace = match => `(${NK_PATH}.can('sticker')||${match.slice(0, -1)})?`; feature = 'stickerPicker';
      } else if (marker === '#{intl::STREAM_FPS_OPTION}') {
        replacements[0].replace = match => {
          const tier = match.slice(match.indexOf(':') + 1).replace(/,$/, '');
          return `...(${NK_PATH}.can('stream')?{}:{guildPremiumTier:${tier}}),`;
        }; feature = 'qualityPicker';
      } else if (marker === '"UserSettingsProtoStore"') feature = 'themeIncoming';
      else if (marker === ',updateTheme(') {
        feature = 'themeSelect';
        // Run before the native function's shouldSync("appearance") return.
        // Standard-theme buttons can also call updateTheme directly.
        replacements.push({
          match: /(function \i\((\i)\)\{)(?=let\{backgroundGradientPresetId:)/,
          replace: (_, head, options) => `${head}${NK_PATH}.handleThemeReset(${options}?.backgroundGradientPresetId);`
        });
        replacements.push({
          match: /(?<=,updateTheme\(\i\)\{)/,
          replace: `${NK_PATH}.handleThemeReset(null);`
        });
      }
      else if (marker === '.CLIENT_THEMES_EDITOR?') {
        replacements[0].replace = match => `(${NK_PATH}.can('themes')||${match})`; feature = 'themeEditor';
      }
      if (marker === '}renderStickersAccessories(') {
        feature = 'renderAccessories';
        replacements[2].match = /renderAttachments\((\i)\){.+?{attachments:(\i).+?;/;
        replacements[2].replace = (match, message, attachments) => `${match}${attachments}=${NK_PATH}.filterAttachments(${attachments},${message});`;
      }
      list.push({ find: canonicalMatch(marker), feature, group: !!patch.group || ['eligibility', 'themeIncoming', 'renderAccessories'].includes(feature), replacements: replacements.filter(r => !r.skip).map(r => ({ match: canonicalMatch(r.match), replace: r.replace })) });
    }
    // Keep this optional newer entitlement independent of the existing group,
    // so a Discord update cannot disable working emoji/sticker/theme hooks.
    list.push({ find: 'canUsePremiumAppIcons:function', feature: 'appIconEligibility', group: true, replacements: [{
      match: canonicalMatch(/(?<=canUsePremiumAppIcons:function\(\i\)\{)/),
      replace: `if(${NK_PATH}.can('appIcons'))return true;`
    }] });
    list.unshift({ find: '.handleSendMessage,onResize:', feature: 'send', group: true, replacements: [{
      match: canonicalMatch(/(?<=channel:\i\}\)\.then\()(?:async )?(\i=>.+?let (\i)=\i\.\i\.parse\((\i),.+?\.getSendMessageOptions\(\{.+?\}\)(?:,location:\i(?:\.\i){1,3}\})?;)(?=.*?(\i)\.flags=)(?<=\)\(({.+?})\)\.then.+?)/),
      replace: (m, rest, parsed, channel, options, props) => `async ${rest}if(await ${NK_PATH}.preSend(${channel}.id,${parsed},${options},${props}))return{shouldClear:false,shouldRefocus:true};`
    }] });
    list.unshift({ find: canonicalMatch('#{intl::EDIT_TEXTAREA_HELP}'), feature: 'edit', group: true, replacements: [{
      match: canonicalMatch(/(?<=,channel:\i,message:\i\}\)\.then\().+?(?=\i\.content!==this\.props\.message\.content&&\i\((.+?)\)\})/),
      replace: (match, args) => `async ${match}if(await ${NK_PATH}.preEdit(${args}))return Promise.resolve({shouldClear:false,shouldRefocus:true});`
    }] });
    return list;
  }
  const patches = patchList();
  const wrappedFactories = new WeakMap();
  function wrapFactory(factory) {
    if (typeof factory !== 'function') return factory;
    const cached = wrappedFactories.get(factory); if (cached) return cached;
    let text = sourceOf(factory), changed = false; const features = [];
    if (text.length < 2 * 1024 * 1024) for (const patch of patches) {
      if (typeof patch.find === 'string' ? !text.includes(patch.find) : !patch.find.test(text)) continue;
      let candidate = text, matches = 0, failed = false;
      for (const replacement of patch.replacements) {
        let count = 0;
        const next = candidate.replace(replacement.match, (...args) => {
          count++;
          if (count > 32) { failed = true; return args[0]; }
          let result = typeof replacement.replace === 'function' ? replacement.replace(...args) : replacement.replace;
          if (typeof replacement.replace !== 'function') result = result.replace(/\$\$|\$&|\$(\d{1,2})/g, (whole, n) => whole === '$$' ? '$' : whole === '$&' ? args[0] : args[Number(n)] ?? whole);
          return String(result).replaceAll('$self', NK_PATH);
        });
        if (!count && patch.group) { failed = true; break; }
        if (count) { candidate = next; matches += count; }
      }
      if (!failed && matches && candidate !== text) { text = candidate; features.push(patch.feature); changed = true; }
    }
    let compiled = factory;
    if (changed) {
      try {
        // Webpack also emits object-method factories: 12345(e,t,n){...}.
        // Function#toString preserves that shorthand, which is not a valid
        // standalone expression. Normalize only its declaration, not the body.
        let expression = text.trim();
        if (!/^(?:async\s+)?function\b/.test(expression)) {
          const method = expression.match(/^(async\s+)?(?:\d+|[A-Za-z_$][\w$]*|"[^"\\]+"|'[^'\\]+')\s*\(/);
          if (method) expression = (method[1] || '') + 'function(' + expression.slice(method[0].length);
        }
        compiled = Function('return (' + expression + '\n)')();
      }
      catch { status.set('compatibility', 'Some features do not match this Discord version.'); features.length = 0; }
    }
    const wrapped = function(module) {
      const result = Reflect.apply(compiled, this, arguments);
      if (active) {
        record(module?.exports);
        for (const feature of features) compiledFeatures.add(feature);
      }
      return result;
    };
    Object.defineProperty(wrapped, Symbol.for('noko.discord.factory-adapter.v1'), {
      value: rewrite => { compiled = rewrite(compiled); }
    });
    wrappedFactories.set(factory, wrapped); wrappedFactories.set(wrapped, wrapped); return wrapped;
  }
  let chunkArray = null, savedPushDescriptor = null, pushGetter = null, pushSetter = null, latestPush = null;
  const capturedRuntimes = new WeakSet(), ownedTables = [];
  let bootstrapChunk = null, runtimeCaptured = false;
  function captureRuntime(require) {
    if (!active || typeof require !== 'function' || capturedRuntimes.has(require)) return;
    const table = require.m, cache = require.c;
    if (!table || typeof table !== 'object') return;
    const ids = Object.keys(table);
    if (ids.length > 20000) { status.set('runtime', 'Discord changed its startup modules. Reload after a Tan update.'); return; }
    capturedRuntimes.add(require); runtimeCaptured = true;
    // Discord's main bundle owns a lexical factory table. It never arrives in
    // a pushed chunk, so capture it before the bootstrap starts the app.
    const owned = [];
    for (const id of ids) {
      const original = table[id], wrapped = wrapFactory(original);
      if (wrapped !== original) { table[id] = wrapped; owned.push([id, original, wrapped]); }
    }
    ownedTables.push([table, owned]);
    // Observe exports already initialized by the bootstrap without requiring
    // (and therefore executing) any application modules ourselves.
    if (cache && typeof cache === 'object') for (const id of Object.keys(cache).slice(0, 20000)) record(cache[id]?.exports);
  }
  function patchChunk(chunk) {
    if (!active || !Array.isArray(chunk) || !chunk[1] || typeof chunk[1] !== 'object') return;
    for (const id of Object.keys(chunk[1])) chunk[1][id] = wrapFactory(chunk[1][id]);
  }
  function restorePush() {
    if (!chunkArray) return;
    const queued = bootstrapChunk && chunkArray.indexOf(bootstrapChunk);
    if (typeof queued === 'number' && queued >= 0) chunkArray.splice(queued, 1);
    bootstrapChunk = null;
    const descriptor = Object.getOwnPropertyDescriptor(chunkArray, 'push');
    if (descriptor?.get === pushGetter && descriptor?.set === pushSetter) {
      if (savedPushDescriptor) Object.defineProperty(chunkArray, 'push', 'value' in savedPushDescriptor ? { ...savedPushDescriptor, value: latestPush } : savedPushDescriptor);
      else { delete chunkArray.push; if (latestPush !== Array.prototype.push) chunkArray.push = latestPush; }
    }
    chunkArray = null;
  }
  function installHook() {
    if (!active) return;
    const array = Array.isArray(globalThis.webpackChunkdiscord_app) ? globalThis.webpackChunkdiscord_app : [];
    if (array === chunkArray) return;
    restorePush(); chunkArray = array; savedPushDescriptor = Object.getOwnPropertyDescriptor(array, 'push'); latestPush = array.push;
    for (const chunk of array) patchChunk(chunk);
    // Preserve other Tans' symbol markers. A plain wrapper hides Morgana's
    // ownership marker and makes it install another wrapper on every focus.
    const pushWrappers = new WeakMap();
    const wrapPush = original => {
      let wrapped = pushWrappers.get(original);
      if (!wrapped) {
        wrapped = new Proxy(original, {
          apply(target, receiver, chunks) {
            if (active) for (const chunk of chunks) patchChunk(chunk);
            return Reflect.apply(target, receiver, chunks);
          }
        });
        pushWrappers.set(original, wrapped);
      }
      return wrapped;
    };
    const inheritedPush = typeof savedPushDescriptor?.get === 'function' && typeof savedPushDescriptor?.set === 'function';
    // Retain preceding hook owners in either installation order. Webpack's
    // delegate replacement must reach every accessor layer, including the app's
    // independent browser stream controls.
    const priorPush = savedPushDescriptor;
    pushGetter = () => wrapPush(inheritedPush ? priorPush.get.call(array) : latestPush);
    pushSetter = next => {
      if (typeof next !== 'function' || next === pushGetter()) return;
      latestPush = next;
      if (inheritedPush) priorPush.set.call(array, next);
    };
    try { Object.defineProperty(array, 'push', { configurable: true, enumerable: false, get: pushGetter, set: pushSetter }); globalThis.webpackChunkdiscord_app = array; }
    catch { status.set('compatibility', 'Reload Discord to activate the compatibility hooks.'); }
    // Webpack invokes queued runtime callbacks before its application entry
    // point. If bootstrap is already running, its push delegate invokes this
    // immediately instead. The unique chunk contains no application modules.
    bootstrapChunk = [['noko-fake-nitro-runtime-' + Math.random().toString(36).slice(2)], {}, captureRuntime];
    array.push(bootstrapChunk);
  }
  function stop() {
    if (!active) return;
    active = false; control.active = false; generation++;
    for (const controller of pending) controller.abort(); pending.clear();
    for (const close of [...dialogs]) close(); dialogs.clear();
    panel?.remove(); panel = null; launcher?.remove(); launcher = null; restorePush();
    for (const [table, owned] of ownedTables) for (const [id, original, wrapped] of owned) {
      if (table[id] === wrapped) table[id] = original;
    }
    ownedTables.length = 0;
    if (appliedLocalTheme && remoteAppearance) {
      try {
        const proto = PreloadedUserSettingsActionCreators.ProtoClass.create(); proto.appearance = remoteAppearance;
        FluxDispatcher.dispatch({ type: 'USER_SETTINGS_PROTO_UPDATE', local: true, partial: true, settings: { type: 1, proto } });
      } catch {}
    }
    remoteAppearance = null; records.length = 0; queries.clear(); compiledFeatures.clear();
    // Already compiled Discord functions can refer to this small inert bridge
    // until reload. Every method above becomes a passthrough when inactive.
  }
  control.stop = stop;
  /* NOKO_FAKE_NITRO_UI */
  installHook();
  api.register({
    start() { api.onCleanup(stop); },
    resume() { installHook(); },
    navigationChanged() { installHook(); },
    stop
  });
