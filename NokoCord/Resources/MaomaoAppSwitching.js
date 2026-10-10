if (window !== window.top || location.origin !== 'https://discord.com') return;
globalThis.__maomaoAppSwitching?.destroy();
let button, observer, visible = true;
const style = document.createElement('style');
style.id = 'noko-app-switch-style';
style.textContent = `
/* Noko-Glass folds two global actions into the header. The third action needs
   its own width and matching search clearance; removing it restores both. */
html:has(:is([class^="trailing_"], [class*=" trailing_"]) > #noko-maolist-switch) { --maomao-app-switch-width:40px; }
#noko-maolist-switch { display:flex;align-items:center;justify-content:center;align-self:center;flex:0 0 32px;width:32px;height:32px;box-sizing:border-box;margin:0;padding:4px;border:0;border-radius:8px;background:transparent;cursor:pointer; }
#noko-maolist-switch img { display:block;width:24px;height:24px;object-fit:cover;border-radius:6px;pointer-events:none; }
#noko-maolist-switch.noko-hovered { background:var(--background-modifier-hover,rgba(128,128,128,.12)); }
#noko-maolist-switch:focus-visible { outline:2px solid var(--text-link,#72cdb4);outline-offset:2px; }
`;
function mount() {
  if (!visible || button?.isConnected) return;
  // The utility toolbar's public Help link is independent of Discord's locale.
  const help = Array.from(document.querySelectorAll('a[href*="support.discord.com"]')).find(link => {
    const bounds = link.getBoundingClientRect();
    return link.querySelector('svg') && bounds.width > 0 && bounds.height > 0 && bounds.top < 120 && bounds.left > innerWidth / 2;
  });
  if (!help) return;
  let anchor = help, toolbar = help.parentElement;
  for (let depth = 0; toolbar && depth < 6; depth++) {
    const layout = getComputedStyle(toolbar);
    if (layout.display.includes('flex') && layout.flexDirection === 'row' && toolbar.children.length > 1) break;
    anchor = toolbar; toolbar = toolbar.parentElement;
  }
  if (!toolbar || anchor.parentElement !== toolbar || !getComputedStyle(toolbar).display.includes('flex')) return;
  button?.remove();
  button = document.createElement('button'); button.id = 'noko-maolist-switch'; button.type = 'button';
  button.title = 'Switch to MaoList (⇧⌘M)'; button.setAttribute('aria-label', 'Switch to MaoList');
  const image = document.createElement('img'); image.src = icons[1]; image.alt = '';
  button.append(image);
  button.addEventListener('pointerenter', () => button.classList.add('noko-hovered'));
  button.addEventListener('pointerleave', () => button.classList.remove('noko-hovered'));
  button.addEventListener('click', e => {
    if (!e.isTrusted || !visible) return;
    button.classList.remove('noko-hovered'); button.blur();
    globalThis.webkit?.messageHandlers.maomaoSwitchApp.postMessage('maolist');
  });
  toolbar.insertBefore(button, anchor.nextSibling);
}
function setVisible(value) {
  visible = value; observer?.disconnect();
  if (!visible && button) { button.classList.remove('noko-hovered'); button.blur(); }
  if (visible) {
    mount(); observer = new MutationObserver(mount);
    observer.observe(document.body, {childList:true,subtree:true});
  }
}
document.head.append(style);
globalThis.__maomaoAppSwitching = {
  setVisible,
  destroy() { visible = false; observer?.disconnect(); button?.remove(); style.remove(); delete globalThis.__maomaoAppSwitching; }
};
setVisible(true);
