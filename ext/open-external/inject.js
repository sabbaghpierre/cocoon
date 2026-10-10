// webapp-kit link router — MAIN-world shim (document_start, top frame only).
// Runs in the page's own JS world so it can patch the REAL window.open:
// content scripts run in an isolated world, where overriding window.open has
// no effect on the page. Requires Chromium >= 111 ("world":"MAIN").
//
// It only forwards http(s) popups to the isolated content script via
// postMessage; that script owns the native-host bridge. If nothing bridges
// (host missing), the content script falls back to a real popup.
'use strict';

(() => {
  if (window.__webappkitRouterInjected) return;
  window.__webappkitRouterInjected = true;

  const rawOpen = window.open;
  const MARKER = 1;

  function isHttpUrl(url) {
    return url.protocol === 'http:' || url.protocol === 'https:';
  }

  window.open = function (url, ...rest) {
    if (typeof url === 'string') {
      let parsed = null;
      try {
        parsed = new URL(url, window.location.href);
      } catch (e) {
        parsed = null;
      }
      if (parsed && isHttpUrl(parsed)) {
        try {
          window.postMessage(
            { __webappkitRouter: MARKER, kind: 'open', url: parsed.href },
            '*'
          );
        } catch (e) {
          /* postMessage should never throw here, but never break the page */
        }
        return null;
      }
    }
    return rawOpen.call(window, url, ...rest);
  };
})();
