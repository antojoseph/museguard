# Local browser bridge

The Chrome extension uses `com.antojoseph.museguard` native messaging. Chrome
launches the small Python host, which verifies the extension's exact stable
origin and forwards bounded, length-prefixed JSON over the companion app's
private Unix socket. It has no model credential, TCP listener, or cloud client.
Up to four native requests can run concurrently so an action check can reach
the app while an earlier page check is waiting. The app makes the scheduling
and analysis decisions. Responses retain their original IDs.

Prepare a reviewable host package without changing Chrome:

```sh
python3 scripts/install-browser-host.py
```

After reviewing the extension permissions and host package, explicitly install
its user-level registration:

```sh
python3 scripts/install-browser-host.py --install
```

This does not load or enable the extension. Chrome's **Load unpacked** step is
separate. The companion must be running; unavailable, malformed or oversized
requests remain unassessed and produce a review response, never a safe verdict.
Text snapshots exclude passwords and entered form values. An explicit screenshot
check includes the visible tab's pixels, which can contain visible form values.
The native app removes URL user information, query strings and fragments from
text before analysis.
Raw browser content is not logged by this host.

Closing Chrome's native connection cancels queued forwarding and closes active
application connections. The app cancels their pending analysis rather than
finishing obsolete browser work. CLI diagnostics that send a single frame and
close stdin must pass `--one-shot` to wait for the final response; Chrome does
not use that option.

The protocol and macOS host location follow the [official Chrome native messaging
documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
