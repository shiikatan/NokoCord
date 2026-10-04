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
        // Newer Discord viewers use a full-window dialog with generic class
        // names. Exclude ordinary profile/settings dialogs and their avatars.
        const rect = root.getBoundingClientRect();
        return rect.width >= innerWidth * 0.85 && rect.height >= innerHeight * 0.8;
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
        observer.observe(root, {childList:true, subtree:true, attributes:true, attributeFilter:['src','srcset','class','style','aria-hidden']});
        update();
    }
    function discover(node) {
        if (!(node instanceof Element)) return;
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
            for (const change of changes) for (const node of change.addedNodes) discover(node);
        }).observe(document.body, {childList:true, subtree:true});
    }
    if (document.body) start();
    else document.addEventListener('DOMContentLoaded', start, {once:true});
})();
