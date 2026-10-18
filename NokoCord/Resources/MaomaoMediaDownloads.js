// Maomao browser integration, independent of Tans and Noko-Glass.
(() => {
    'use strict';
    if (window !== top || location.origin !== 'https://discord.com' || globalThis.__maomaoMediaDownloads) return;
    const bridge = () => globalThis.webkit?.messageHandlers?.maomaoMediaDownload;
    const knownViewer = '[class*="imageModal_"], [class*="carouselModal_"], [class*="mediaViewer_"]';
    const roots = '[role="dialog"], ' + knownViewer;
    const viewers = new Map();
    let context = null;

    function installButtonStyle() {
        const style = document.createElement('style');
        style.dataset.maomaoMediaDownloadStyle = '';
        style.textContent = `
            button[data-maomao-media-download] {
                appearance: none; box-sizing: border-box; display: inline-flex;
                align-items: center; justify-content: center; align-self: center;
                flex: none; gap: 8px; width: 32px; height: 32px; min-width: 32px; min-height: 32px;
                margin: 0; padding: 0; border: 0; border-radius: 8px;
                background: transparent; color: var(--interactive-normal, #b5bac1);
                font: 500 14px var(--font-primary, system-ui); cursor: pointer; pointer-events: auto;
                transition: background-color .12s ease, color .12s ease;
            }
            button[data-maomao-media-download]:hover {
                background: var(--background-modifier-hover, rgba(255,255,255,.08));
                color: var(--interactive-hover, var(--text-normal, #fff));
            }
            button[data-maomao-media-download]:active {
                background: var(--background-modifier-active, rgba(255,255,255,.14));
            }
            button[data-maomao-media-download]:focus { outline: none; }
            button[data-maomao-media-download]:focus-visible {
                outline: 2px solid var(--focus-primary, #8bbcff); outline-offset: 2px;
            }
            button[data-maomao-media-download] svg { width: 20px; height: 20px; flex: none; }
            button[data-maomao-media-download][data-placement="floating"] {
                width: auto; height: 40px; padding: 0 14px; border-radius: 12px;
                border: 1px solid var(--border-subtle, rgba(255,255,255,.14));
                background: color-mix(in srgb, var(--background-floating, #202127) 85%, transparent);
                color: var(--text-normal, #fff); backdrop-filter: blur(16px);
                -webkit-backdrop-filter: blur(16px); box-shadow: 0 4px 16px rgba(0,0,0,.18);
            }
            button[data-maomao-media-download][data-placement="floating"]:hover {
                background: var(--background-floating, #202127);
            }
            @media (prefers-reduced-motion: reduce) {
                button[data-maomao-media-download] { transition: none; }
            }
            @media (prefers-reduced-transparency: reduce) {
                button[data-maomao-media-download][data-placement="floating"] {
                    background: var(--background-floating, #202127); backdrop-filter: none;
                    -webkit-backdrop-filter: none;
                }
            }
            @media (forced-colors: active) {
                button[data-maomao-media-download] { color: ButtonText; }
                button[data-maomao-media-download]:focus-visible { outline-color: Highlight; }
            }

/* NokoGlass expression browser. Discord retains masonry coordinates and handlers. */
[data-noko-gif-shell] {
    --ng-panel: rgb(30 31 34 / 52%);
    --ng-wash: rgb(30 31 34 / 48%);
    --ng-chrome: rgb(255 255 255 / 5%);
    --ng-card-radius: 18px;
    --ng-line: rgb(255 255 255 / 18%);
    --ng-field: rgb(255 255 255 / 9%);
    --ng-text: #f2f3f5;
    --ng-muted: #c2c4ca;
    --ng-focus: rgb(255 255 255 / 52%);
    --ng-ink: var(--ng-text);
    color: var(--ng-text);
    position: relative;
    isolation: isolate;
    background: transparent !important;
    border-radius: 18px !important;
    box-shadow: inset 0 0 0 1px var(--ng-line), inset 0 1px rgb(255 255 255 / 14%), 0 18px 48px rgb(0 0 0 / 35%) !important;
    -webkit-backdrop-filter: none !important;
    backdrop-filter: none !important;
}
/* Blur only a separate backing sheet, never an ancestor of video surfaces. */
[data-noko-gif-shell]::before {
    content: "";
    position: absolute;
    inset: 0;
    z-index: -1;
    pointer-events: none;
    border-radius: inherit;
    background: radial-gradient(ellipse at top left, rgb(255 255 255 / 12%), transparent 65%), linear-gradient(var(--ng-wash), var(--ng-wash)), var(--custom-theme-background, var(--ng-panel));
    background-attachment: fixed;
    -webkit-backdrop-filter: blur(24px) saturate(1.35);
    backdrop-filter: blur(24px) saturate(1.35);
}
.theme-light [data-noko-gif-shell] {
    --ng-panel: rgb(248 249 252 / 62%);
    --ng-wash: rgb(248 249 252 / 60%);
    --ng-chrome: rgb(255 255 255 / 12%);
    --ng-line: rgb(30 31 34 / 18%);
    --ng-field: rgb(255 255 255 / 65%);
    --ng-text: #202127;
    --ng-muted: #555965;
    --ng-focus: rgb(30 31 34 / 50%);
}
/* Keep Discord's legacy and current surface tokens local to this menu. */
[data-noko-gif-shell], [data-noko-expression-panel] {
    --focus-primary: var(--ng-focus);
    --input-focused-border: var(--ng-focus);
    --background-primary: transparent;
    --background-secondary: transparent;
    --background-secondary-alt: var(--ng-field);
    --background-tertiary: transparent;
    --background-floating: var(--ng-chrome);
    --background-base-lowest: transparent;
    --background-base-lower: transparent;
    --background-base-low: transparent;
    --background-surface-high: var(--ng-chrome);
    --background-surface-higher: var(--ng-field);
    --background-surface-highest: var(--ng-field);
    --background-mod-subtle: var(--ng-field);
    --background-mod-strong: var(--ng-field);
    --background-modifier-hover: var(--ng-field);
    --background-modifier-selected: var(--ng-field);
    --text-normal: var(--ng-text);
    --text-primary: var(--ng-text);
    --text-secondary: var(--ng-muted);
    --interactive-normal: var(--ng-muted);
    --interactive-hover: var(--ng-text);
    --interactive-active: var(--ng-focus);
}
[data-noko-expression-panel]:not([data-noko-gif-shell]),
[data-noko-gif-shell] :is([class^="body_"], [class*=" body_"], [class^="listWrapper_"], [class*=" listWrapper_"], [class^="results_"], [class*=" results_"], [class^="nav_"], [class*=" nav_"], [class^="emojiPicker_"], [class*=" emojiPicker_"], [class^="stickerPicker_"], [class*=" stickerPicker_"]) {
    background: transparent !important;
}
[data-noko-gif-shell] :is([class^="header_"], [class*=" header_"], [class^="headerLabel_"], [class*=" headerLabel_"], [class^="categoryHeader_"], [class*=" categoryHeader_"], [class^="packHeader_"], [class*=" packHeader_"], [class^="inspector_"], [class*=" inspector_"], [class^="footer_"], [class*=" footer_"]) {
    /* One continuous backing sheet across the picker. A second tinted fill
     * here made the search strip and sticky labels a different color. */
    background: transparent !important;
    color: var(--ng-text);
    box-shadow: none !important;
}
[data-noko-gif-shell] :is([class^="categoryList_"], [class*=" categoryList_"], [class^="categoryListWithSearch_"], [class*=" categoryListWithSearch_"]) {
    background: transparent !important;
}
[data-noko-gif-shell] :is([class^="categoryItem_"], [class*=" categoryItem_"])[aria-selected="true"] {
    background: var(--ng-field) !important;
    color: var(--ng-focus) !important;
}
[data-noko-gif-shell] :is([role="tab"], [class^="navButton_"], [class*=" navButton_"]) {
    color: var(--ng-muted) !important;
    border-radius: 10px;
    transition: background-color .12s ease, color .12s ease;
}
[data-noko-gif-shell] :is([role="tab"][aria-selected="true"], [class*="navButtonActive_"]) {
    background: var(--ng-field) !important;
    color: var(--ng-ink) !important;
    box-shadow: inset 0 0 0 1px var(--ng-line), 0 2px 10px rgb(0 0 0 / 8%);
}
[data-noko-gif-shell] :is([role="tab"], [class^="navButton_"], [class*=" navButton_"]):hover {
    background-color: var(--ng-field);
}
[data-noko-gif-search] {
    background: var(--ng-field) !important;
    border: none !important;
    border-radius: 12px !important;
    box-shadow: inset 0 0 0 1px var(--ng-line), inset 0 1px rgb(255 255 255 / 16%) !important;
}
[data-noko-gif-search]:focus-within {
    box-shadow: inset 0 0 0 1px var(--ng-focus), 0 0 0 3px var(--ng-field) !important;
}
[data-noko-expression-panel] input {
    color: var(--ng-text) !important;
    background: transparent !important;
    caret-color: var(--ng-focus);
}
[data-noko-gif-shell] :focus-visible { outline-color: var(--ng-focus) !important; }
[data-noko-expression-panel] input::placeholder { color: var(--ng-muted); }
[data-noko-gif-panel] :is([class^="result_"], [class*=" result_"]) {
    border-radius: var(--ng-card-radius) !important;
    overflow: hidden;
    background-color: rgb(17 25 26 / 65%) !important;
    outline: 1px solid var(--ng-line);
    outline-offset: -1px;
}
[data-noko-gif-panel] :is([class^="result_"], [class*=" result_"]):is(:hover, :focus-visible) {
    outline: 2px solid var(--ng-focus);
    outline-offset: -2px;
}
/* Size every GIF preview layer against its card. Clip at the card only:
 * avoid separate rounded clipping surfaces when Discord swaps posters and video. Favorite/label overlays stay put. */
[data-noko-gif-panel] :is([class^="result_"], [class*=" result_"]) > :is(img, video, [class^="gif_"], [class*=" gif_"]) {
    display: block;
    position: absolute !important;
    inset: 0 !important;
    margin: 0 !important;
    width: 100% !important; height: 100% !important;
    max-width: none !important; max-height: none !important;
    object-fit: contain !important; object-position: center !important;
    background-size: contain !important;
    background-position: center !important;
    background-repeat: no-repeat !important;
    border-radius: 0 !important;
}
[data-noko-gif-panel] :is([class^="result_"], [class*=" result_"]) > :is([class^="gif_"], [class*=" gif_"]) :is(img, video) {
    position: absolute !important;
    inset: 0 !important;
    margin: 0 !important;
    width: 100% !important; height: 100% !important;
    max-width: none !important; max-height: none !important;
    object-fit: contain !important; object-position: center !important;
    border-radius: 0 !important;
}
/* Draw decoded frames without WebKit's independently scaled video layer. */
[data-noko-gif-frame] {
    position: absolute !important; inset: 0 !important;
    width: 100% !important; height: 100% !important;
    pointer-events: none !important; border-radius: 0 !important; z-index: 1 !important;
}
[data-noko-gif-panel] video[data-noko-preview-covered] { opacity: .001 !important; }
[data-noko-gif-panel] :is([class^="favButton_"], [class*=" favButton_"]) { z-index: 2 !important; }
[data-noko-search-backing], [data-noko-search-backing]::before,
[data-noko-search-backing]::after,
[data-noko-section-heading], [data-noko-section-heading] * {
    background: transparent !important;
    box-shadow: none !important;
    backdrop-filter: none !important; -webkit-backdrop-filter: none !important;
}
[data-noko-search-backing] { border-color: transparent !important; }
[data-noko-gif-search], [data-noko-gif-search] * {
    outline: none !important;
    --input-border: transparent;
    --input-focused-border: var(--ng-focus);
}
[data-noko-gif-search] :is(input, [class*="container_"]) {
    border: none !important; box-shadow: none !important;
}
[data-noko-expression-panel]:not([data-noko-gif-shell]) {
    backdrop-filter: none !important; -webkit-backdrop-filter: none !important;
    box-shadow: none !important; border-color: transparent !important;
}
/* Discord keeps its last inspected sticker for the footer. That is not a
 * pointer hover. Preserve its keyboard navigation cue without a stuck tile. */
[data-noko-gif-shell]:not([data-noko-picker-keyboard]) :is([class^="sticker_"], [class*=" sticker_"]):not(:hover):not(:focus-within),
[data-noko-gif-shell]:not([data-noko-picker-keyboard]) :is([class^="sticker_"], [class*=" sticker_"]):not(:hover):not(:focus-within)::before,
[data-noko-gif-shell]:not([data-noko-picker-keyboard]) :is([class^="sticker_"], [class*=" sticker_"]):not(:hover):not(:focus-within)::after {
    background: transparent !important;
    box-shadow: none !important;
}
[data-noko-gif-shell]:not([data-noko-picker-keyboard]) :is([class^="sticker_"], [class*=" sticker_"]):not(:hover):not(:focus-within) :is([class^="inspectedIndicator_"], [class*=" inspectedIndicator_"]) {
    opacity: 0 !important;
}
/* Keep Discord's dark category scrim and label above decoded video frames. */
[data-noko-gif-panel] :is([class^="categoryFade_"], [class*=" categoryFade_"], [class^="categoryFadeBlurple_"], [class*=" categoryFadeBlurple_"]) { z-index: 2 !important; }
[data-noko-gif-panel] :is([class^="categoryText_"], [class*=" categoryText_"]) { z-index: 3 !important; }
/* Category cover art and its dark label overlay share the same rounded edge. */
[data-noko-gif-panel] :is([class^="categoryFade_"], [class*=" categoryFade_"], [class^="categoryFadeBlurple_"], [class*=" categoryFadeBlurple_"], [class^="categoryText_"], [class*=" categoryText_"]) {
    border-radius: var(--ng-card-radius) !important;
}
@media (prefers-reduced-transparency: reduce) {
    [data-noko-gif-shell] { --ng-panel: #252d2e; --ng-chrome: #2d3837; }
    [data-noko-gif-shell]::before { background: var(--ng-panel); -webkit-backdrop-filter: none; backdrop-filter: none; }
    .theme-light [data-noko-gif-shell] { --ng-panel: #f3f7f5; }
}
@media (prefers-reduced-motion: reduce) {
    [data-noko-gif-shell] * { transition: none !important; }
}
@media (forced-colors: active) {
    [data-noko-gif-shell] { color: CanvasText; }
    [data-noko-gif-shell]::before { background: Canvas; -webkit-backdrop-filter: none; backdrop-filter: none; }
    [data-noko-gif-shell] [aria-selected="true"] { background: Highlight !important; color: HighlightText !important; }
}

        `;
        (document.head || document.documentElement).appendChild(style);
    }

    function usable(raw) {
        if (!raw || raw.length > 8 * 1024 * 1024) return null;
        try {
            const url = new URL(raw, location.href);
            if (url.username || url.password) return null;
            if (url.protocol === 'https:' ||
                (url.protocol === 'blob:' && url.origin === location.origin) ||
                (url.protocol === 'data:' && /^data:image\//i.test(raw))) return url.href;
        } catch {}
        return null;
    }
    function sources(element) {
        if (!(element instanceof Element)) return {};
        const image = element.closest('img');
        const media = element.closest('video, audio');
        return {
            image: image ? usable(image.currentSrc || image.src) : null,
            media: media ? usable(media.currentSrc || media.src) : null,
            link: usable(element.closest('a[href]')?.href)
        };
    }
    window.addEventListener('contextmenu', event => {
        if (!event.isTrusted) return;
        context = sources(event.composedPath().find(node => node instanceof Element));
    }, true);

    globalThis.__maomaoMediaDownloads = Object.freeze({
        contextURL(kind, x, y) {
            const saved = context;
            context = null;
            if (saved?.[kind]) return saved[kind];
            // The native menu supplies its original click position as a
            // fallback when a page handler prevented the contextmenu event.
            for (const element of document.elementsFromPoint(x * innerWidth, y * innerHeight)) {
                const value = sources(element)[kind];
                if (value) return value;
            }
            return null;
        }
    });

    function visibleImage(root) {
        let selected = null, area = 0;
        for (const image of root.querySelectorAll('img')) {
            if (image.closest('[aria-hidden="true"]')) continue;
            const rect = image.getBoundingClientRect();
            if (rect.width < 96 || rect.height < 96) continue;
            const style = getComputedStyle(image);
            if (style.visibility === 'hidden' || style.display === 'none') continue;
            const width = Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left));
            const height = Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top));
            const nextArea = width * height;
            if (nextArea > area && usable(image.currentSrc || image.src)) { selected = image; area = nextArea; }
        }
        return selected;
    }
    function isImageViewer(root) {
        if (root.matches(knownViewer) || root.querySelector(knownViewer)) return true;
        // Dialog size is not evidence of a media viewer: profiles and the
        // avatar GIF picker can fill the window too. Generic viewer shells
        // need a media-viewer label or actual zoom controls.
        const label = root.getAttribute('aria-label') || '';
        if (/\b(?:media|image) viewer\b/i.test(label)) return true;
        return !!root.querySelector('[aria-label="Zoom In"], [aria-label="Zoom Out"], [data-testid="media-viewer"]');
    }
    function watch(root) {
        root = root.closest('[role="dialog"]') || root;
        if (viewers.has(root)) return;
        const button = document.createElement('button');
        button.type = 'button';
        button.title = 'Download image';
        button.setAttribute('aria-label', 'Download image');
        button.dataset.maomaoMediaDownload = '';
        button.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12m-5-5 5 5 5-5M4 16v4h16v-4"/></svg><span>Download image</span>';
        button.addEventListener('click', event => {
            event.preventDefault(); event.stopPropagation();
            if (!event.isTrusted) return;
            const image = visibleImage(root);
            const url = image && usable(image.currentSrc || image.src);
            if (url) bridge()?.postMessage(url);
        });
        let frame = 0;
        function update() {
            frame = 0;
            if (!root.isConnected) { dispose(); return; }
            if (!isImageViewer(root) || !visibleImage(root)) { button.remove(); return; }
            const toolbar = root.querySelector('[role="toolbar"], [class*="actionButtons_"], [class*="toolbar_"]');
            const parent = toolbar || root;
            const placement = toolbar ? 'toolbar' : 'floating';
            if (button.dataset.placement !== placement) button.dataset.placement = placement;
            if (toolbar) {
                button.style.position = 'relative'; button.style.right = ''; button.style.bottom = ''; button.style.zIndex = '';
                button.querySelector('span').hidden = true;
            } else {
                button.style.position = 'fixed'; button.style.right = '24px'; button.style.bottom = '24px'; button.style.zIndex = '10';
                button.querySelector('span').hidden = false;
            }
            if (button.parentElement !== parent) parent.appendChild(button);
        }
        function schedule() { if (!frame) frame = requestAnimationFrame(update); }
        const observer = new MutationObserver(changes => {
            // Ignore our own placement/styling to avoid an observer feedback loop.
            if (changes.every(change => change.target === button || button.contains(change.target) ||
                (change.type === 'childList' && [...change.addedNodes, ...change.removedNodes].every(node => node === button)))) return;
            schedule();
        });
        function dispose() {
            observer.disconnect(); if (frame) cancelAnimationFrame(frame);
            for (const event of ['load', 'transitionend', 'animationend']) root.removeEventListener(event, schedule, true);
            button.remove(); viewers.delete(root);
        }
        viewers.set(root, dispose);
        for (const event of ['load', 'transitionend', 'animationend']) root.addEventListener(event, schedule, true);
        observer.observe(root, {childList:true, subtree:true, attributes:true, attributeFilter:['src','srcset','class','style','aria-hidden','aria-label']});
        update();
    }
    const gifFrames = new Map();
    function frameGIF(video) {
        if (gifFrames.has(video)) return;
        const card = video.closest('[class^="result_"], [class*=" result_"]');
        if (!card) return;
        const canvas = document.createElement('canvas');
        canvas.setAttribute('data-noko-gif-frame', '');
        canvas.setAttribute('aria-hidden', 'true');
        canvas.hidden = true;
        // Insert alongside the preview, before favorite/label overlays. React
        // retains its video and handlers; no second network request or decoder.
        video.after(canvas);
        const ctx = canvas.getContext('2d', {alpha: false});
        let visible = false, disposed = false, pending = null, last = -Infinity;
        const nativeFrames = typeof video.requestVideoFrameCallback === 'function';
        function stop() {
            if (pending === null) return;
            if (nativeFrames) video.cancelVideoFrameCallback(pending);
            else cancelAnimationFrame(pending);
            pending = null;
        }
        function schedule() {
            if (disposed || !visible || document.hidden || pending !== null || video.paused || !ctx) return;
            pending = nativeFrames ? video.requestVideoFrameCallback(draw) : requestAnimationFrame(draw);
        }
        function draw(now = performance.now()) {
            pending = null;
            if (disposed || !visible || document.hidden) return;
            if (video.readyState >= 2 && video.videoWidth && now - last >= 30) {
                const rect = video.getBoundingClientRect();
                const dpr = Math.min(devicePixelRatio || 1, 2);
                const w = Math.round(rect.width * dpr), h = Math.round(rect.height * dpr);
                if (w && h) {
                    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
                    const scale = Math.min(w / video.videoWidth, h / video.videoHeight);
                    const dw = video.videoWidth * scale, dh = video.videoHeight * scale;
                    try {
                        ctx.fillStyle = '#192023'; ctx.fillRect(0, 0, w, h);
                        ctx.drawImage(video, (w - dw) / 2, (h - dh) / 2, dw, dh);
                        canvas.hidden = false;
                        video.setAttribute('data-noko-preview-covered', '');
                        last = now;
                    } catch (_) { canvas.hidden = true; video.removeAttribute('data-noko-preview-covered'); }
                }
            }
            schedule();
        }
        function refresh() { stop(); draw(); }
        function reset() { video.removeAttribute('data-noko-preview-covered'); canvas.hidden = true; last = -Infinity; refresh(); }
        const observer = new IntersectionObserver(entries => {
            visible = entries[0].isIntersecting;
            refresh();
        });
        observer.observe(video);
        const resize = new ResizeObserver(() => { last = -Infinity; refresh(); });
        resize.observe(video);
        const events = {playing: refresh, loadeddata: reset, emptied: reset, pause: stop, error: reset};
        for (const [event, handler] of Object.entries(events)) video.addEventListener(event, handler);
        document.addEventListener('visibilitychange', refresh);
        const dispose = () => {
            disposed = true; stop(); observer.disconnect(); resize.disconnect();
            for (const [event, handler] of Object.entries(events)) video.removeEventListener(event, handler);
            document.removeEventListener('visibilitychange', refresh);
            video.removeAttribute('data-noko-preview-covered');
            canvas.remove(); gifFrames.delete(video);
        };
        dispose.canvas = canvas;
        gifFrames.set(video, dispose);
    }

    function decorateGIFPicker(node) {
        const selector = '#gif-picker-tab-panel, #emoji-picker-tab-panel, #sticker-picker-tab-panel, #stickers-picker-tab-panel';
        const panels = new Set([node.closest(selector), ...node.querySelectorAll(selector)].filter(Boolean));
        for (const panel of panels) {
            const shell = panel.closest('[class^="contentWrapper_"], [class*=" contentWrapper_"]') || panel;
            if (!shell.hasAttribute('data-noko-gif-shell')) {
                shell.setAttribute('data-noko-gif-shell', '');
                shell.addEventListener('pointermove', () => shell.removeAttribute('data-noko-picker-keyboard'), {passive:true});
                shell.addEventListener('keydown', event => {
                    if (['Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) shell.setAttribute('data-noko-picker-keyboard', '');
                });
            }
            if (!panel.hasAttribute('data-noko-expression-panel')) panel.setAttribute('data-noko-expression-panel', '');
            if (panel.id === 'gif-picker-tab-panel' && !panel.hasAttribute('data-noko-gif-panel')) panel.setAttribute('data-noko-gif-panel', '');
            if (panel.id === 'gif-picker-tab-panel') for (const video of panel.querySelectorAll('video')) frameGIF(video);
            for (const heading of panel.querySelectorAll('[class^="header_"], [class*=" header_"], [class^="categoryHeader_"], [class*=" categoryHeader_"], [role="heading"]')) {
                if (!heading.querySelector('input')) heading.setAttribute('data-noko-section-heading', '');
            }
            for (const input of panel.querySelectorAll('input')) {
                const field = input.closest('[class^="searchBar_"], [class*=" searchBar_"], [class^="searchBarComponent_"], [class*=" searchBarComponent_"]') || input.parentElement;
                if (field && !field.hasAttribute('data-noko-gif-search')) field.setAttribute('data-noko-gif-search', '');
                // Search headers differ across GIF/sticker/emoji tabs. Clear the
                // actual ancestor chain rather than guessing one hashed class.
                for (let backing = field?.parentElement; backing && backing !== shell; backing = backing.parentElement) {
                    if (!backing.hasAttribute('data-noko-search-backing')) backing.setAttribute('data-noko-search-backing', '');
                }
            }
        }
    }

    function discover(node) {
        if (!(node instanceof Element)) return;
        decorateGIFPicker(node);
        if (node.matches(roots)) watch(node);
        for (const root of node.querySelectorAll(roots)) watch(root);
    }
    function start() {
        installButtonStyle();
        discover(document.body);
        // Only inspect newly inserted subtrees. Image selection and attribute
        // observation are confined to open dialogs; there is no polling.
        new MutationObserver(changes => {
            for (const [root, dispose] of viewers) if (!root.isConnected) dispose();
            for (const [video, dispose] of [...gifFrames]) {
                if (!video.isConnected) dispose();
                else if (!dispose.canvas.isConnected || dispose.canvas.parentElement !== video.parentElement) {
                    dispose();
                    if (video.closest('[data-noko-gif-panel]')) frameGIF(video);
                }
            }
            for (const change of changes) for (const node of change.addedNodes) discover(node);
        }).observe(document.body, {childList:true, subtree:true});
    }
    if (document.body) start();
    else document.addEventListener('DOMContentLoaded', start, {once:true});
})();
