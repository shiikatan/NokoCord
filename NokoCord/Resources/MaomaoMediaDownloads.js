// Maomao browser integration, independent of Tans and Noko-Glass.
(() => {
    'use strict';
    if (window !== top || location.origin !== 'https://discord.com' || globalThis.__maomaoMediaDownloads) return;
    const bridge = () => globalThis.webkit?.messageHandlers?.maomaoMediaDownload;
    const knownViewer = '[class*="imageModal_"], [class*="carouselModal_"], [class*="mediaViewer_"]';
    const roots = '[role="dialog"], ' + knownViewer;
    const viewers = new Map();
    let context = null, workspaceVisible = true;

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
    isolation: isolate;
    background: transparent !important;
    border-radius: 18px !important;
    box-shadow: inset 0 0 0 1px var(--ng-line), inset 0 1px rgb(255 255 255 / 14%), 0 18px 48px rgb(0 0 0 / 35%) !important;
    -webkit-backdrop-filter: none !important;
    backdrop-filter: none !important;
}
[data-noko-gif-shell][data-noko-shell-static] { position: relative; }
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
        setVisible(value) {
            const next = value === true;
            if (workspaceVisible === next) return;
            workspaceVisible = next;
            refreshMediaVisibility();
        },
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
            for (const [property, value] of Object.entries(toolbar
                ? {position:'relative', right:'', bottom:'', zIndex:''}
                : {position:'fixed', right:'24px', bottom:'24px', zIndex:'10'})) {
                if (button.style[property] !== value) button.style[property] = value;
            }
            const label = button.querySelector('span');
            if (label.hidden !== !!toolbar) label.hidden = !!toolbar;
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
    const gifFrames = new Map(), chatGIFs = new Map();
    const panelSelector = '#gif-picker-tab-panel, #emoji-picker-tab-panel, #sticker-picker-tab-panel, #stickers-picker-tab-panel';
    const chatSelector = '[id^="chat-messages-"]';
    // One observer pair per document, rather than per result in long GIF lists.
    const mediaVisibility = new IntersectionObserver(entries => {
        for (const entry of entries) {
            const record = gifFrames.get(entry.target) || chatGIFs.get(entry.target);
            record?.setVisible(entry.isIntersecting);
        }
    });
    const previewSizes = new ResizeObserver(entries => {
        for (const entry of entries) gifFrames.get(entry.target)?.resize(entry.contentRect);
    });
    function refreshMediaVisibility() {
        for (const record of gifFrames.values()) record.refresh();
        for (const record of chatGIFs.values()) record.refresh();
    }
    document.addEventListener('visibilitychange', refreshMediaVisibility);
    document.addEventListener('play', event => {
        if (event.target instanceof HTMLVideoElement) watchChatGIF(event.target);
    }, true);

    function frameGIF(video) {
        if (gifFrames.has(video)) return;
        const card = video.closest('[class^="result_"], [class*=" result_"]');
        if (!card) return;
        const canvas = document.createElement('canvas');
        canvas.setAttribute('data-noko-gif-frame', '');
        canvas.setAttribute('aria-hidden', 'true');
        canvas.hidden = true;
        canvas.width = canvas.height = 0;
        video.after(canvas);
        const ctx = canvas.getContext('2d', {alpha: false});
        let visible = false, observed = false, disposed = false, pending = null, last = -Infinity;
        // Cache geometry on resize, never force layout for each decoded frame.
        let box = video.getBoundingClientRect();
        const nativeFrames = typeof video.requestVideoFrameCallback === 'function';
        function stop() {
            if (pending === null) return;
            if (nativeFrames) video.cancelVideoFrameCallback(pending);
            else cancelAnimationFrame(pending);
            pending = null;
        }
        function releasePixels() {
            canvas.hidden = true;
            video.removeAttribute('data-noko-preview-covered');
            if (canvas.width || canvas.height) canvas.width = canvas.height = 0;
            last = -Infinity;
        }
        function active() { return !disposed && visible && workspaceVisible && !document.hidden; }
        function schedule() {
            if (!active() || pending !== null || video.paused || video.readyState < 2 || !ctx) return;
            pending = nativeFrames ? video.requestVideoFrameCallback(draw) : requestAnimationFrame(draw);
        }
        function draw(now = performance.now()) {
            pending = null;
            if (!active()) { releasePixels(); return; }
            if (video.readyState >= 2 && video.videoWidth && now - last >= 30) {
                // Preserve Retina rendering for normal cards; bound pathological
                // card dimensions to a 4 MiB RGBA surface instead of hundreds.
                const scaleLimit = Math.sqrt(1024 * 1024 / Math.max(1, box.width * box.height));
                const dpr = Math.min(devicePixelRatio || 1, 2, scaleLimit);
                const w = Math.floor(box.width * dpr), h = Math.floor(box.height * dpr);
                if (w && h) {
                    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
                    const scale = Math.min(w / video.videoWidth, h / video.videoHeight);
                    const dw = video.videoWidth * scale, dh = video.videoHeight * scale;
                    try {
                        ctx.fillStyle = '#192023'; ctx.fillRect(0, 0, w, h);
                        ctx.drawImage(video, (w - dw) / 2, (h - dh) / 2, dw, dh);
                        if (canvas.hidden) canvas.hidden = false;
                        if (!video.hasAttribute('data-noko-preview-covered')) video.setAttribute('data-noko-preview-covered', '');
                        last = now;
                    } catch (_) { releasePixels(); }
                }
            }
            schedule();
        }
        function refresh() { stop(); draw(); }
        function reset() { releasePixels(); refresh(); }
        const events = {playing: refresh, loadeddata: reset, emptied: reset, pause: stop, error: reset};
        for (const [event, handler] of Object.entries(events)) video.addEventListener(event, handler);
        gifFrames.set(video, {
            canvas,
            setVisible(value) {
                if (observed && visible === value) return;
                observed = true; visible = value; refresh();
            },
            resize(rect) { box = rect; last = -Infinity; refresh(); },
            refresh,
            dispose() {
                disposed = true; stop(); releasePixels();
                mediaVisibility.unobserve(video); previewSizes.unobserve(video);
                for (const [event, handler] of Object.entries(events)) video.removeEventListener(event, handler);
                canvas.remove(); gifFrames.delete(video);
            }
        });
        mediaVisibility.observe(video); previewSizes.observe(video);
    }

    function watchChatGIF(video) {
        // Limit playback management to silent autoplay loops in messages.
        // Calls, screen shares, ordinary videos and manual playback stay native.
        if (chatGIFs.has(video) || !video.closest(chatSelector)) return;
        const eligible = () => video.autoplay && video.loop && (video.muted || video.defaultMuted) && !video.controls && !video.srcObject;
        if (!eligible()) return;
        let visible = true, observed = false, pausedByUs = false, disposed = false;
        function refresh() {
            if (disposed) return;
            const canRun = workspaceVisible && !document.hidden && (!observed || visible);
            if (!eligible()) { pausedByUs = false; return; }
            if (!canRun && !video.paused) {
                pausedByUs = true;
                video.pause();
            } else if (canRun && pausedByUs) {
                pausedByUs = false;
                // Resume only playback that this integration paused. Discord's
                // autoplay preference and manual pauses retain their authority.
                video.play().catch(() => {});
            }
        }
        video.addEventListener('play', refresh);
        chatGIFs.set(video, {
            setVisible(value) { observed = true; visible = value; refresh(); },
            refresh,
            dispose() {
                disposed = true; mediaVisibility.unobserve(video);
                video.removeEventListener('play', refresh);
                chatGIFs.delete(video);
                // React can reuse a still-connected video outside the message.
                // Relinquish our pause instead of leaving the new owner stalled.
                if (pausedByUs && video.isConnected && eligible()) video.play().catch(() => {});
                pausedByUs = false;
            }
        });
        mediaVisibility.observe(video);
        refresh();
    }

    const headingSelector = '[class^="header_"], [class*=" header_"], [class^="categoryHeader_"], [class*=" categoryHeader_"], [role="heading"]';
    const panelShells = new WeakMap();
    function decorateGIFPicker(panel, additions = [panel]) {
        const wrapper = panel.closest('[class^="contentWrapper_"], [class*=" contentWrapper_"]');
        const dialog = panel.closest('[role="dialog"]');
        // Standalone Choose GIF has its title outside the tab panel. Give that
        // whole chooser one backing sheet, without touching profile editors or
        // other dialogs which happen to contain an inline expression picker.
        const standalone = !wrapper && dialog && dialog !== panel
            && !dialog.querySelector('form, textarea, [contenteditable="true"], .user-profile-popout, [class^="userProfile"], [class*=" userProfile"], [class^="profile"], [class*=" profile"]');
        let shell = wrapper || panel;
        if (standalone) {
            // The dialog role can belong to a full-window focus wrapper. Use
            // the nearest inner card which owns both title and picker instead.
            const headings = 'h1, h2, [role="heading"], header, [class^="header_"], [class*=" header_"]';
            for (let card = panel.parentElement; card && card !== dialog; card = card.parentElement) {
                if ([...card.querySelectorAll(headings)].some(heading => !panel.contains(heading))) { shell = card; break; }
            }
            if (shell === panel) {
                const bounds = dialog.getBoundingClientRect(), content = panel.getBoundingClientRect();
                if (bounds.width <= content.width + 64 && bounds.width < innerWidth - 32) shell = dialog;
            }
        }
        // A new shell can change existing search ancestors. Full initialization
        // is rare; ordinary result insertion only visits the added subtrees.
        if (panelShells.get(panel) !== shell) {
            const previous = panelShells.get(panel);
            if (previous && (previous === panel || !previous.querySelector(panelSelector))) {
                previous.removeAttribute('data-noko-gif-shell'); previous.removeAttribute('data-noko-shell-static');
            }
            additions = [panel]; panelShells.set(panel, shell);
        }
        if (!shell.hasAttribute('data-noko-gif-shell')) {
            if (getComputedStyle(shell).position === 'static') shell.setAttribute('data-noko-shell-static', '');
            shell.setAttribute('data-noko-gif-shell', '');
            shell.addEventListener('pointermove', () => {
                if (shell.hasAttribute('data-noko-picker-keyboard')) shell.removeAttribute('data-noko-picker-keyboard');
            }, {passive:true});
            shell.addEventListener('keydown', event => {
                if (['Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) shell.setAttribute('data-noko-picker-keyboard', '');
            });
        }
        if (!panel.hasAttribute('data-noko-expression-panel')) panel.setAttribute('data-noko-expression-panel', '');
        if (panel.id === 'gif-picker-tab-panel' && !panel.hasAttribute('data-noko-gif-panel')) panel.setAttribute('data-noko-gif-panel', '');
        const videos = new Set(), headings = new Set(), inputs = new Set();
        for (const root of additions) {
            if (!panel.contains(root)) continue;
            if (root.matches('video')) videos.add(root);
            if (root.matches(headingSelector)) headings.add(root);
            if (root.matches('input')) inputs.add(root);
            for (const node of root.querySelectorAll('video, input, ' + headingSelector)) {
                if (node.matches('video')) videos.add(node);
                if (node.matches('input')) inputs.add(node);
                if (node.matches(headingSelector)) headings.add(node);
            }
        }
        if (panel.id === 'gif-picker-tab-panel') videos.forEach(frameGIF);
        for (const heading of headings) {
            if (!heading.querySelector('input') && heading.getAttribute('data-noko-section-heading') !== '') heading.setAttribute('data-noko-section-heading', '');
        }
        for (const input of inputs) {
            const field = input.closest('[class^="searchBar_"], [class*=" searchBar_"], [class^="searchBarComponent_"], [class*=" searchBarComponent_"]') || input.parentElement;
            if (field && !field.hasAttribute('data-noko-gif-search')) field.setAttribute('data-noko-gif-search', '');
            // Search headers differ across GIF/sticker/emoji tabs. Clear the
            // actual ancestor chain rather than guessing one hashed class.
            for (let backing = field?.parentElement; backing && backing !== shell; backing = backing.parentElement) {
                if (!backing.hasAttribute('data-noko-search-backing')) backing.setAttribute('data-noko-search-backing', '');
            }
        }
    }

    function discover(node, panels) {
        if (!(node instanceof Element)) return;
        const panel = node.closest(panelSelector);
        if (panel) {
            if (!panels.has(panel)) panels.set(panel, []);
            panels.get(panel).push(node);
        }
        if (node.matches(roots)) watch(node);
        if (node.matches('video')) watchChatGIF(node);
        for (const candidate of node.querySelectorAll(roots + ', ' + panelSelector + ', video')) {
            if (candidate.matches(panelSelector)) panels.set(candidate, [candidate]);
            else if (candidate.matches('video')) watchChatGIF(candidate);
            else watch(candidate);
        }
    }
    function start() {
        installButtonStyle();
        const initialPanels = new Map();
        discover(document.body, initialPanels);
        initialPanels.forEach((roots, panel) => decorateGIFPicker(panel, roots));
        const added = new Set();
        let frame = 0, needsSweep = false;
        function flush() {
            frame = 0;
            if (needsSweep) {
                needsSweep = false;
                for (const [root, dispose] of viewers) if (!root.isConnected) dispose();
                for (const [video, record] of [...gifFrames]) {
                    if (!video.isConnected || !video.closest('[data-noko-gif-panel]')) record.dispose();
                    else if (!record.canvas.isConnected || record.canvas.parentElement !== video.parentElement) {
                        record.dispose(); frameGIF(video);
                    }
                }
                for (const [video, record] of chatGIFs) if (!video.isConnected || !video.closest(chatSelector)) record.dispose();
            }
            const panels = new Map();
            for (const node of added) {
                if (!node.isConnected) continue;
                let parent = node.parentElement;
                while (parent && !added.has(parent)) parent = parent.parentElement;
                if (!parent) discover(node, panels);
            }
            added.clear();
            panels.forEach((roots, panel) => decorateGIFPicker(panel, roots));
        }
        new MutationObserver(changes => {
            for (const change of changes) {
                if (change.removedNodes.length) needsSweep = true;
                for (const node of change.addedNodes) {
                    if (node instanceof Element && !node.matches('[data-noko-gif-frame], [data-maomao-media-download]')) added.add(node);
                }
            }
            if (!frame && (added.size || needsSweep)) frame = requestAnimationFrame(flush);
        }).observe(document.body, {childList:true, subtree:true});
    }
    if (document.body) start();
    else document.addEventListener('DOMContentLoaded', start, {once:true});
})();
