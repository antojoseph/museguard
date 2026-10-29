# Muse Guard for Chrome

This Manifest V3 extension connects Chrome to the Muse Guard desktop app. It provides automatic **text checks** of bounded visible page content and redacted destinations, plus an explicit **screenshot check** for visual context. Both use the model on this Mac. The extension never receives the model API key and has no cloud endpoint.

**Every risk explanation and warning control belongs to the native Muse avatar.** The extension injects no warning panel or blocking overlay into websites, shows no risk badge, and renders no model verdict in its popup. The popup contains connection status, global pause/resume controls and manual check buttons.

## Automatic protection

Protection starts on for all normal HTTP/HTTPS web tabs where Chrome permits the content script. There is no per-site opt-in step. Automatic visible-text checks run after page load and relevant changes, with debouncing and duplicate suppression. Destination preflights prepare matching action assessments in advance.

Loading, updating or restarting the extension also attaches to already-open HTTP/HTTPS tabs across Chrome windows. New navigations use the declared content script; activation and restored tabs provide another attachment check. Duplicate attachment requests reuse the same live listener. Discarded tabs start when Chrome restores them, and a saved Pause or disabled setting is preserved.

Tab and Chrome-window activation explicitly refreshes the current tab's protection settings, including recovery from a temporary connection failure. Hidden tabs keep their own background checks. A metadata-only heartbeat reports the global protection state to Muse every 30 seconds, so changing tabs or finishing one inference does not trigger a nap or remove the on-duty glasses. Pause/Disable clears that state immediately; if Chrome disconnects, its native awake lease expires after 90 seconds. The model's real inference activity is tracked separately.

Only a completed, still-current **high-risk** assessment calls Muse over or blocks a matching supported action. Low, medium, unknown and unavailable assessments stay quiet. Normal browsing also continues while an assessment is still running; that does not mean the content has been assessed as safe. A click made before a useful verdict is ready can proceed. This is proactive assistance with cached blocking, not an instantaneous network firewall.

A high-risk page assessment can warn through Muse, but never blanket-blocks that page's links or forms. Blocking requires a fresh, exact high-risk action result, cached for at most 30 seconds and bound to the original page, document, destination and relevant action details. Changed pages or forms cannot reuse an older result. Risk explanations remain beside Muse on the desktop, and a dangerous action stays on the current page. Chrome retains the complete local destination URL; redacted analysis URLs are never substituted into navigation.

The visible high-risk explanation stays with Muse until you choose **Got it**. Browser cache expiry, navigation and cleanup still invalidate browser decisions, but do not acknowledge or dismiss a warning already shown by Muse. **Got it** dismisses that explanation only; it does not allow a high-risk action.

### Pause and resume

The toolbar popup offers:

- **Pause 30 minutes** — pauses automatic protection, then resumes automatically. Chrome's alarm and persisted expiry make the timed pause survive closing the popup or restarting the service worker.
- **Pause until resumed** — keeps automatic protection paused until you choose **Resume protection**.
- **Resume protection** — restores automatic checks and requests fresh page assessments.

Pausing stops new automatic reads and clears cached decisions and pending extension-side protection state. Late results cannot trigger a warning after protection is paused. The popup shows the remaining time in plain language and refreshes it every 30 seconds while open. Pause and Resume remain available on Chrome internal pages and new tabs; manual check buttons are available only on supported websites. Explicit text and screenshot checks remain available while automatic protection is paused.

Existing development installs migrate to this global behavior. The old site allowlist is ignored. A previously disabled global setting stays paused until you explicitly resume it.

## Manual checks and avatar warnings

When a user asks Muse a chat question while Chrome is the source app, the desktop companion requests a fresh snapshot of the active tab. The extension polls a metadata-only mailbox over its existing local connection; it reads and sends page text only when that explicit one-time request exists. It checks the tab, window, URL, document and visible content again before replying, omits form values, and sends no automatic screenshot. This explicit chat path remains available while automatic protection is paused. The context is consumed once and expires after six seconds.

**Check text** sends the current visible text and bounded destination metadata. **Check screenshot** captures the current visible tab for visual analysis. The popup shows only whether the check completed; findings are presented by Muse. Keep the real toolbar popup focused and open until a manual check finishes. Opening `popup.html` as an ordinary tab cannot capture or analyze content.

A fresh, matching high-risk action result can stop that specific click or submission. Muse explains the concern, and the high-risk warning offers no override. Closing the warning does not release or replay the action. Clicking the same still-dangerous action again can bring the warning back, using a metadata-only reference to the recent native finding; it does not send the page evidence again merely to redisplay that warning.

Each native warning has its own presentation ID, so closing an older warning cannot dismiss a newer one. Cached findings keep their original expiry rather than extending their lifetime on each use. Unknown and in-progress checks do not pause navigation or form submission.

The extension never copies form values, submits a form itself, or replays a click after inference. When no exact, fresh high-risk result exists, Chrome handles the original action normally with its usual validation.

## Data handling

- Text extraction skips inputs, textareas, selects, editable elements, hidden elements, scripts, embedded frames and areas marked `data-private` or `data-muse-private`. It never reads field `.value` properties. Nested private or hidden content is excluded from labels too.
- Page titles, visible text, bounded link/form metadata and action labels may contain personal information shown by a website. Automatic checks apply globally; use Pause when you do not want visible content checked locally.
- URL user information, query strings and fragments are stripped before analysis, including literal URLs in collected text. Complete navigation URLs remain inside Chrome so actions retain their original query parameters.
- A requested screenshot includes **everything visible in that tab**, including visible form values. Chrome captures only that tab, then locally resizes the image to at most 1600 pixels on its long edge and a JPEG data URL below 2 MB. Images are not saved. No continuous screenshot monitoring is started by this extension.
- Protection and pause settings use `chrome.storage.local`. Only check-completion metadata uses session storage. Raw page text, screenshots and short-lived receipts stay in memory; no browsing history is stored.
- Assessments use [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging). The service worker handles automatic requests; explicit checks communicate directly from the toolbar popup. The model credential stays in the native app.
- Native presentation, repeated high-risk warnings and cancellation use metadata-only routes. The extension rechecks current context before asking Muse to present a finding; stale results cannot rehydrate a paused cache or block a changed action.

## Install and update

Build the desktop app and register the native host using the repository's browser-bridge setup instructions. Load **this folder** as an unpacked extension from `chrome://extensions`. Its public manifest key provides a stable development ID; the host installer derives its exact allowed origin from that key. No private extension signing key is included.

After loading, open a normal website and the extension's toolbar popup. It should say **Muse is ready** once the desktop app and local model are available, and automatic protection should show **On** for **All websites**. No site approval button is needed. A preserved disabled setting instead shows **Paused** with Resume available.

**Reload the extension once after updating its files.** Reopening the popup does not load new worker code or manifest permissions. The updated extension attaches to existing web tabs without reloading their pages. If upgrading from a much older development version that injected warning panels or lacked listener cleanup, refreshing an affected tab once removes those old handlers and panels.

## Scope

This version operates in the main frame. It cannot guarantee interception of hostile page JavaScript, programmatic `form.submit()` or fetch requests, redirects, iframe actions, browser UI actions, context-menu navigation or independent downloads. Browser-native protections remain in place. Model judgments can be wrong, and automatic analysis can arrive after a user action. Unknown, incomplete and unavailable assessments are not safe verdicts, even though this quiet policy lets normal browsing continue.

The implementation uses an [isolated content script](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts), a service worker and the toolbar popup. HTTP/HTTPS host access enables injection. It uses `nativeMessaging`, `storage`, `activeTab`, `alarms` and [`scripting`](https://developer.chrome.com/docs/extensions/reference/api/scripting) to attach the bundled scripts to already-open tabs; it requests no cookies, browsing-history, debugger or web-request permission. Chrome internal pages and other extension-restricted pages are excluded. Incognito requires Chrome's separate user-controlled allowance. Executable code is bundled locally.

## Checks

```sh
npm ci --ignore-scripts
npm test
```

Virtual-DOM and worker checks exercise real extraction and protection code, no-warning-DOM/popup guarantees, private-field filtering, exact page/action signatures, raw local URL changes, fresh high-risk blocking, immediate passage for unknown or incomplete checks, global queue bounds, pause-generation races, cache expiry without renewal, global protection defaults and persisted pause controls. Native app/protocol tests and real-model probes are separate. These tests do not install or enable the extension in a Chrome profile.
