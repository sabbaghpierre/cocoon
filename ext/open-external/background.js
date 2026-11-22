// Cocoon link router — background service worker.
// Relays {type:'cocoon-open', url} from the content script to the
// com.cocoon.open_external native host (bin/cocoon-open-external),
// which hands the URL to the system default browser via xdg-open.
'use strict';

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.type !== 'cocoon-open' || typeof msg.url !== 'string') {
    sendResponse({ ok: false, error: 'bad-message' });
    return false;
  }
  try {
    chrome.runtime.sendNativeMessage(
      'com.cocoon.open_external',
      { url: msg.url },
      (response) => {
        if (chrome.runtime.lastError) {
          sendResponse({ ok: false, error: String(chrome.runtime.lastError.message || chrome.runtime.lastError) });
        } else {
          sendResponse({ ok: !!(response && response.ok) });
        }
      }
    );
  } catch (e) {
    sendResponse({ ok: false, error: String((e && e.message) || e) });
    return false;
  }
  return true; // async sendResponse
});
