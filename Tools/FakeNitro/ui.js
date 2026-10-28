  // Controls live in NokoCord's native Tan details, not in the chat surface.
  function restoreRemoteTheme() {
    if (!appliedLocalTheme || !remoteAppearance) return;
    try {
      const proto = PreloadedUserSettingsActionCreators.ProtoClass.create(); proto.appearance = remoteAppearance;
      FluxDispatcher.dispatch({ type: 'USER_SETTINGS_PROTO_UPDATE', local: true, partial: true, settings: { type: 1, proto } });
      appliedLocalTheme = false;
    } catch {}
  }
  control.updateSettings = values => {
    if (!active || !values || typeof values !== 'object' || Array.isArray(values)) return false;
    const beforeThemes = settings.store.enableThemes;
    for (const key of Object.keys(settings.store)) {
      const value = values[key];
      if (typeof value !== typeof settings.store[key]) continue;
      if ((key === 'emojiSize' || key === 'stickerSize') && !mediaSizes.includes(value)) continue;
      settings.store[key] = key === 'hyperLinkText' ? value.slice(0, 120) : value;
    }
    persistSettings();
    if (beforeThemes && !settings.store.enableThemes) restoreRemoteTheme();
    else if (!beforeThemes && settings.store.enableThemes && localTheme) {
      try { applyTheme(localTheme.theme, localTheme.preset); } catch {}
    }
    return true;
  };
  control.statusSnapshot = () => ({
    active,
    emoji: ready('emoji'), sticker: ready('sticker'), themes: ready('themes'), stream: ready('stream'), appIcons: ready('appIcons'),
    messages: [...new Set([
      ...status.values(),
      ...(!runtimeCaptured ? ['Reload Discord to connect to its startup modules.'] : [])
    ])].slice(0, 8).map(value => String(value).slice(0, 160))
  });
