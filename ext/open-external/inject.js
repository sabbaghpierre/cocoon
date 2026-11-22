// Cocoon link router — MAIN-world shim (document_start, top frame only).
// Runs in the page's own JS world so it can patch the REAL window.open:
// content scripts run in an isolated world, where overriding window.open has
// no effect on the page. Requires Chromium >= 111 ("world":"MAIN").
'use strict';

(() => {
  if (window.__cocoonRouterInjected) return;
  window.__cocoonRouterInjected = true;

  const rawOpen = window.open;
  const MARKER = 1;
  // Shared with the isolated content script through the DOM (JS globals are
  // NOT shared between worlds). Prevents page scripts forging router messages.
  const nonce = Math.random().toString(36).slice(2) + Date.now().toString(36);
  try {
    document.documentElement.setAttribute('data-cocoon-router', nonce);
  } catch (e) {
    /* documentElement may not exist yet at document_start */
  }

  function isHttpUrl(url) {
    return url.protocol === 'http:' || url.protocol === 'https:';
  }

  window.open = function (url, target, features) {
    if (typeof url === 'string') {
      let parsed = null;
      try {
        parsed = new URL(url, window.location.href);
      } catch (e) {
        parsed = null;
      }
      if (parsed && isHttpUrl(parsed)) {
        // Same-origin popups and explicit-size (OAuth/SSO style) popups must
        // stay in the app: their postMessage/cookie callback completes here.
        const sameOrigin = parsed.origin === window.location.origin;
        const oauthLike = typeof features === 'string' && features.length > 0;
        if (!sameOrigin && !oauthLike) {
          try {
            window.postMessage(
              {
                __cocoonRouter: MARKER,
                nonce,
                kind: 'open',
                url: parsed.href,
              },
              window.location.origin
            );
          } catch (e) {
            /* never break the page */
          }
          return null;
        }
      }
    }
    return rawOpen.call(window, url, target, features);
  };
})();
