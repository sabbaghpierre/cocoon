// Cocoon link router — content script (document_start, top frame only).
// Rule: EVERY http(s) link activation leaves the isolated cocoon window and
// opens in the system default browser via the native host (xdg-open).
// The cocoon window itself only ever shows its pinned start URL (+ in-page
// JS-router state, which performs no real navigation).
//
// window.open() is handled by the sibling MAIN-world script (inject.js): a
// content script runs in an isolated world, so patching window.open HERE
// would never affect the page. inject.js posts {__cocoonRouter:1} back to
// this world, which owns the native-host bridge.
//
// If the native host is unreachable (manifest not installed), fall back to
// normal behavior so links never die silently.
'use strict';

const HOST_OK_TIMEOUT_MS = 1500;

function isHttpUrl(url) {
  return url.protocol === 'http:' || url.protocol === 'https:';
}

function askHost(url, onDone) {
  // No extension context (shouldn't happen): report failure.
  if (!chrome || !chrome.runtime || !chrome.runtime.sendMessage) {
    onDone(false);
    return;
  }
  let settled = false;
  const timer = setTimeout(() => {
    if (!settled) {
      settled = true;
      onDone(false);
    }
  }, HOST_OK_TIMEOUT_MS);
  try {
    chrome.runtime.sendMessage({ type: 'cocoon-open', url }, () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      onDone(!chrome.runtime.lastError);
    });
  } catch (e) {
    if (!settled) {
      settled = true;
      clearTimeout(timer);
      onDone(false);
    }
  }
}

// mode: 'navigate' (link click) | 'popup' (window.open from the page).
function routeOut(url, mode) {
  askHost(url, (ok) => {
    if (ok) return; // default browser has the URL; do nothing more.
    if (mode === 'popup') {
      // Isolated-world window.open is the native one (inject.js only patched
      // the page's binding), so this opens a real popup as a last resort.
      try {
        window.open(url, '_blank');
      } catch (e) {
        /* nothing else we can do */
      }
    } else {
      window.location.href = url;
    }
  });
}

function linkForEvent(event) {
  const t = event.target;
  if (!t || !t.closest) return null;
  const a = t.closest('a[href]');
  if (!a) return null;
  // Downloads stay in-app (they are not navigation).
  if (a.hasAttribute('download')) return null;
  let url;
  try {
    url = new URL(a.getAttribute('href'), window.location.href);
  } catch (e) {
    return null;
  }
  if (!isHttpUrl(url)) return null; // mailto:/tel:/etc. keep Chrome's OS-handler path
  // Same-document fragment: not navigation, stay.
  if (url.href.split('#')[0] === window.location.href.split('#')[0] && url.hash) {
    return null;
  }
  return url.href;
}

// Primary click (includes Enter-key activation, which dispatches click).
document.addEventListener(
  'click',
  (event) => {
    if (event.defaultPrevented) return;
    // Only the main button; modifiers are meaningless without a tab strip,
    // so they route out like everything else.
    if (event.button !== undefined && event.button !== 0) return;
    const href = linkForEvent(event);
    if (!href) return;
    event.preventDefault();
    event.stopPropagation();
    routeOut(href, 'navigate');
  },
  true
);

// Middle-click (auxclick) on links.
document.addEventListener(
  'auxclick',
  (event) => {
    if (event.defaultPrevented || event.button !== 1) return;
    const href = linkForEvent(event);
    if (!href) return;
    event.preventDefault();
    event.stopPropagation();
    routeOut(href, 'navigate');
  },
  true
);

// window.open() from the page, relayed by inject.js (MAIN world).
window.addEventListener('message', (event) => {
  if (event.source !== window) return;
  const data = event.data;
  if (!data || data.__cocoonRouter !== 1 || data.kind !== 'open') return;
  // The nonce is planted by inject.js in the DOM (shared between JS worlds).
  const nonce = document.documentElement.getAttribute('data-cocoon-router');
  if (!nonce || data.nonce !== nonce) return;
  if (typeof data.url !== 'string') return;
  let url;
  try {
    url = new URL(data.url, window.location.href);
  } catch (e) {
    return;
  }
  if (!isHttpUrl(url)) return;
  routeOut(url.href, 'popup');
});
