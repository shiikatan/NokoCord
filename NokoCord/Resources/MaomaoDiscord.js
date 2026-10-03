// Declarative selectors handle SPA navigation and transient surfaces. Native
// Noko-Glass preferences only change this stylesheet's root gate. No observer,
// polling, network access, event interception, or DOM reparenting.
'use strict';
if (window.top !== window || location.origin !== 'https://discord.com') return;
if (!presentationEnabled) {
    document.documentElement.removeAttribute('data-maomao-discord');
    return;
}
if (!document.getElementById('maomao-discord-presentation')) {
    const style = document.createElement('style');
    style.id = 'maomao-discord-presentation';
    style.textContent = stylesheet;
    (document.head || document.documentElement).appendChild(style);
}
document.documentElement.setAttribute('data-maomao-discord', '');
