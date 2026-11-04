# Local browser bridge

The Chrome extension uses `com.antojoseph.museguard` native messaging. Chrome
launches a host that verifies the extension's exact stable origin and forwards
bounded, length-prefixed JSON over the companion app's private Unix socket.
It has no model credential, TCP listener, or cloud client.
Separate bounded workers let short controls and page checks reach the app
while completed downloads are being scanned. The app makes the scheduling and
analysis decisions. Responses retain their original IDs.

## Installed app

The installer bundles a signed Swift host and the extension. The app's Chrome
setup registers the helper for the current macOS user without requiring Python
or administrator access. In Chrome, open `chrome://extensions`, enable
**Developer mode**, choose **Load unpacked**, and select the folder shown in
Muse Guard's setup. If you previously loaded the development extension, replace
that copy with the bundled folder. Both copies use the same extension ID.

## Source development

Prepare a reviewable host package without changing Chrome:

```sh
python3 scripts/install-browser-host.py
```

After reviewing the extension permissions and host package, explicitly install
its user-level registration:

```sh
python3 scripts/install-browser-host.py --install
```

This registers the development Python host. Chrome's **Load unpacked** step is
separate. The companion must be running. Unavailable requests produce a review
response, while malformed or oversized frames close the connection.
Text snapshots exclude passwords and entered form values. Browser checks are
automatic and text-only; the extension has no manual screenshot route. The
native app removes URL user information, query strings and fragments from text
before analysis. Metadata-only monitoring controls synchronize one persisted
Pause/Resume state across Chrome and optional desktop checks.
Raw browser content is not logged by this host.

Closing Chrome's native connection cancels queued forwarding and closes active
application connections. The app cancels their pending analysis rather than
finishing obsolete browser work. CLI diagnostics that send a single frame and
close stdin must pass `--one-shot` to wait for the final response; Chrome does
not use that option.

The protocol and macOS host location follow the [official Chrome native messaging
documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
Chrome documents its supported installation methods in [Distribute your extension](https://developer.chrome.com/docs/extensions/how-to/distribute).

Control traffic and fast download metadata checks use two workers with sixteen
accepted requests. Page analysis uses four workers with eight accepted requests.
Completed-file inspections use two separate workers with four accepted requests.
These limits include running and queued requests. A full lane cannot consume
another lane's capacity, so file scans cannot delay page monitoring, global
Pause, secret warnings or pointer updates. Exact download phases determine the
lane; malformed phases receive no control priority. Framing and identifiers are
checked before admission, and the app validates the complete protocol before
file access. All three lanes are revoked when Chrome closes its connection.
