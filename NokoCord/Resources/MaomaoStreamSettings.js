// Restore Discord's own browser stream controls without changing entitlement
// checks, permissions, capture sources, audio, or native-platform identity.
(() => {
    'use strict';
    if (window.top !== window || location.origin !== 'https://discord.com') return;
    const KEY = Symbol.for('noko.stream-settings.v1');
    const FACTORY = Symbol.for('noko.discord.factory-adapter.v1');
    if (globalThis[KEY]) return;
    let active = true;
    const tracks = new WeakMap(), transformed = new WeakMap(), runtimes = new WeakSet();
    const path = "globalThis[Symbol.for('noko.stream-settings.v1')]";
    const supportsFrameRate = () => {
        try { return navigator.mediaDevices?.getSupportedConstraints?.().frameRate === true; }
        catch { return false; }
    };
    function numericRate(value) {
        const number = typeof value === 'number' ? value : value?.ideal ?? value?.max;
        return Number.isFinite(number) && number >= 1 && number <= 120 ? number : null;
    }
    function screenConnection(connection, context, rate) {
        try { return active && connection?.context === context && connection.hasDesktopSource?.() === true && numericRate(rate) !== null && supportsFrameRate(); }
        catch { return false; }
    }
    function boundedRate(track, requested) {
        let rate = numericRate(requested);
        try {
            const range = track.getCapabilities?.().frameRate;
            if (Number.isFinite(range?.min)) rate = Math.max(rate, range.min);
            if (Number.isFinite(range?.max)) rate = Math.min(rate, range.max);
        } catch { /* WebKit versions can omit optional capability ranges. */ }
        return rate;
    }
    function applyTrack(connection, context, track, width, height, rate) {
        if (!screenConnection(connection, context, rate) || track?.kind !== 'video' || typeof track.applyConstraints !== 'function') return false;
        let state = tracks.get(track);
        if (!state) { state = { running: false, next: null }; tracks.set(track, state); }
        state.next = { width, height, rate };
        if (state.running) return true;
        state.running = true;
        void (async () => {
            try {
                while (active && state.next && track.readyState !== 'ended') {
                    const next = state.next; state.next = null;
                    const original = track.getConstraints();
                    const constraints = { ...original, frameRate: { ideal: boundedRate(track, next.rate), max: boundedRate(track, next.rate) } };
                    if (Number.isFinite(next.width) && next.width > 0) constraints.width = { max: next.width };
                    if (Number.isFinite(next.height) && next.height > 0) constraints.height = { max: next.height };
                    if (JSON.stringify(constraints) === JSON.stringify(original)) continue;
                    try { await track.applyConstraints(constraints); }
                    catch (error) {
                        // An unsupported rate must not break sharing or lose the
                        // existing resolution update. Keep the previous FPS.
                        if (!active || track.readyState === 'ended' || state.next) continue;
                        if (error?.name === 'OverconstrainedError' || error?.name === 'TypeError') {
                            const fallback = { ...constraints };
                            if ('frameRate' in original) fallback.frameRate = original.frameRate;
                            else delete fallback.frameRate;
                            try { await track.applyConstraints(fallback); } catch {}
                        }
                    }
                }
            } catch { /* Retain Discord's current capture if a track disappears. */ }
            finally { state.running = false; state.next = null; }
        })();
        return true;
    }
    const control = {
        get active() { return active; },
        menuAvailable: () => active,
        canFrameRate: screenConnection,
        applyTrack,
        captureConstraints(value) {
            // Discord's browser capture used to overwrite every requested rate
            // with 30. Keep that default, but honor a supported explicit request.
            return { ...value, frameRate: active && supportsFrameRate() && numericRate(value?.frameRate) !== null ? value.frameRate : 30 };
        },
        stop() { active = false; }
    };
    Object.defineProperty(globalThis, KEY, { value: control, configurable: true });
    function rewrite(factory) {
        if (!active || typeof factory !== 'function') return factory;
        const previous = transformed.get(factory); if (previous) return previous;
        let source = Function.prototype.toString.call(factory), changed = false;
        if (source.length > 2 * 1024 * 1024) return factory;
        if (source.includes('id:"stream-settings"')) {
            let count = 0;
            source = source.replace(/([A-Za-z_$][\w$]*\.isPlatformEmbedded)(?=\?[^;]{0,220}id:"stream-settings")/g, match => { count++; return `(${match}||${path}.menuAvailable())`; });
            if (count > 1) return factory;
            changed ||= count === 1;
        }
        if (source.includes('DesktopInputPool: Input not from this pool')) {
            let count = 0;
            source = source.replace(/video:\{\.\.\.([A-Za-z_$][\w$]*),frameRate:30\}(?=\};if\(navigator\.mediaDevices\?\.getDisplayMedia)/g,
                (_, constraints) => { count++; return `video:${path}.captureConstraints(${constraints})`; });
            if (count > 1) return factory;
            changed ||= count === 1;
        }
        if (source.includes('BaseWebRTCConnection.updateVideoQuality: old:')) {
            const args = source.match(/updateVideoQualityCore\(([A-Za-z_$][\w$]*),[A-Za-z_$][\w$]*\)\{/);
            const context = source.match(/this\.context===([A-Za-z_$][\w$]*)\.x\.DEFAULT/);
            if (args && context) {
                // The native loop reuses the parameter name for its track.
                // Read the requested rate before entering that shadowed scope.
                const requested = `${args[1]}.remoteSinkWantsMaxFramerate`, rate = 'nokoBrowserStreamFrameRate', stream = `${context[1]}.x.STREAM`;
                if (source.includes(rate)) return factory;
                let count = 0;
                source = source.replace(/if\(null!=([A-Za-z_$][\w$]*)&&null!=([A-Za-z_$][\w$]*)\)for\(let ([A-Za-z_$][\w$]*) of ([A-Za-z_$][\w$]*)\.getTracks\(\)\)\{(?=let [A-Za-z_$][\w$]*=\3\.getConstraints\(\))/g,
                    (_, width, height, track, media) => { count++; return `const ${rate}=${requested};if((null!=${width}&&null!=${height})||${path}.canFrameRate(this,${stream},${rate}))for(let ${track} of ${media}.getTracks()){if(${path}.applyTrack(this,${stream},${track},${width},${height},${rate}))continue;`; });
                if (count > 1) return factory;
                changed ||= count === 1;
            }
        }
        if (!changed) { transformed.set(factory, factory); return factory; }
        try {
            let expression = source.trim();
            if (!/^(?:async\s+)?function\b/.test(expression)) {
                const method = expression.match(/^(async\s+)?(?:\d+|[A-Za-z_$][\w$]*|"[^"\\]+"|'[^'\\]+')\s*\(/);
                if (method) expression = (method[1] || '') + 'function(' + expression.slice(method[0].length);
            }
            const compiled = Function('return (' + expression + '\n)')();
            transformed.set(factory, compiled); transformed.set(compiled, compiled); return compiled;
        } catch { transformed.set(factory, factory); return factory; }
    }
    function adapt(factory) {
        // FakeNitro records module completion through its own wrapper. Let it
        // retain that wrapper while applying browser controls to its delegate.
        const adapter = factory?.[FACTORY];
        if (typeof adapter === 'function') {
            try { adapter(rewrite); } catch { /* Keep unsupported wrappers intact. */ }
            return factory;
        }
        return rewrite(factory);
    }
    function chunk(value) {
        if (!active || !Array.isArray(value) || !value[1] || typeof value[1] !== 'object') return;
        for (const id of Object.keys(value[1]).slice(0, 20000)) value[1][id] = adapt(value[1][id]);
    }
    function capture(require) {
        if (!active || typeof require !== 'function' || runtimes.has(require) || !require.m) return;
        const ids = Object.keys(require.m); if (ids.length > 20000) return;
        runtimes.add(require);
        for (const id of ids) require.m[id] = adapt(require.m[id]);
    }
    const array = Array.isArray(globalThis.webpackChunkdiscord_app) ? globalThis.webpackChunkdiscord_app : [];
    for (const value of array) chunk(value);
    const pushWrappers = new WeakMap();
    const wrap = delegate => {
        let wrapped = pushWrappers.get(delegate);
        if (!wrapped) {
            wrapped = new Proxy(delegate, { apply(target, receiver, values) {
                if (active) for (const value of values) chunk(value);
                return Reflect.apply(target, receiver, values);
            } });
            pushWrappers.set(delegate, wrapped);
        }
        return wrapped;
    };
    const priorPush = Object.getOwnPropertyDescriptor(array, 'push');
    const inheritedPush = typeof priorPush?.get === 'function' && typeof priorPush?.set === 'function';
    let delegate = array.push;
    const getPush = () => wrap(inheritedPush ? priorPush.get.call(array) : delegate);
    const setPush = value => {
        if (typeof value !== 'function' || value === getPush()) return;
        // Keep earlier hook owners connected when Webpack replaces its push
        // delegate. Otherwise only initial modules, not lazy chunks, are patched.
        if (inheritedPush) priorPush.set.call(array, value);
        else delegate = value;
    };
    try {
        Object.defineProperty(array, 'push', { configurable: true, get: getPush, set: setPush });
        globalThis.webpackChunkdiscord_app = array;
        array.push([['noko-stream-settings-' + Math.random().toString(36).slice(2)], {}, capture]);
    } catch { /* Unsupported runtimes keep Discord's original browser behavior. */ }
})();
