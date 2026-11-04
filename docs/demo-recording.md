# Muse Guard in three minutes

Use a clean Chrome profile with only the demo tabs. Start the local fixture server from the checkout.

```sh
python3 Development/protection-demo.py
```

| Scene | Local URL | What to verify before filming |
| --- | --- | --- |
| Ordinary browsing and chat | `http://127.0.0.1:8767/guide` | Muse answers that returns are accepted within 30 days of delivery and approved refunds take five business days. The chat header names the current Chrome page. |
| Staged phishing link | `http://127.0.0.1:8767/inbox` | Let Muse check the page and link. Click **Verify your account**. A successful block leaves the inbox open and `/metrics` shows no increase in `link_arrivals`. |
| Staged sign-in | `http://127.0.0.1:8767/phishing` | Muse presents a warning about the staged sign-in. If you show a blocked submission, verify that the page stays in place and `/metrics` shows no increase in `submitted`. If the harmless form reaches `/collect`, record the warning-only cut. |
| Secret paste | `http://127.0.0.1:8767/` | Click **Copy public test phrase**, focus **Test message**, and press Command-V. Muse warns, the field stays empty, and **Page paste events** stays at zero. |

Film the actual `MuseGuard-0.1.0-arm64.pkg` installation from Finder. After launching Muse Guard from Applications, show the Settings window that opens on first run. Record **Download model** starting and label the 19.8 GB download as time-compressed. If the model is already installed, show **Model ready**. **Open Chrome setup** copies the bundled extension folder path and opens `chrome://extensions`. Enable **Developer mode**, click **Load unpacked**, press Command-Shift-G in the folder picker, paste the path, and choose the folder.

Record a short display-capture test that includes both Chrome and Muse. The release app asks macOS to exclude its floating panels from capture. If the panels are absent, use the development app with `--visual-test` for the functional shots and label those shots **Recording build · capture enabled**. Keep the actual Chrome window in front while filming the checks.

The sign-in is a local fixture. It has no external destinations, and its inputs have no names, so the browser submits no field values even if the harmless form reaches the server. Leave those fields empty. For the paste scene, use only the supplied public test vector. Start each take with Muse ready and active, and acknowledge any previous warning. Turn on **Show model predictions** for the checking shot. Allow time for the actual verdict and trim the wait in the edit.

| Time | Picture | Voiceover |
| --- | --- | --- |
| 0:00–0:15 | Open on Muse beside the Harbor guide. Let the avatar settle before the title appears. | “Most of the time, I want to browse without interruptions. When something asks me to hand over a password or a recovery phrase, I want help right there. This is Muse Guard.” |
| 0:15–0:45 | Open the package in Finder and show the macOS installer. Launch Muse Guard from Applications. Show **Download model**, then **Model ready**. Use **Open Chrome setup**, enable **Developer mode**, and use **Load unpacked** with the copied folder path. End on **Muse is ready** and **Active**. | “I install Muse Guard from its Mac package and open it from Applications. On first run, I download the local model. Open Chrome setup copies the extension’s folder path. I enable Developer mode, choose Load unpacked, and paste that path. Supported tabs are now checked automatically.” |
| 0:45–1:08 | Scroll the guide. Click Muse and ask “How long do I have to return an item, and when will the refund arrive?” Show the Chrome source label and the answer. | “On this ordinary page, Muse stays beside the browser. I can ask about the return policy without copying anything. Muse reads the active tab through the extension and answers from the guide.” |
| 1:08–1:58 | Open the staged inbox. Show the model readout while Muse checks the link, then click **Verify your account**. If the click is blocked, hold on the warning and the unchanged inbox. Ask “Why did you warn me?” Return to the warning and choose **Got it**. If the link goes through, record the warning on the staged sign-in instead. | “This staged email threatens account deletion and sends me to a page asking for a password and an authenticator code. Muse checks in the background. When it has a fresh high-risk result for this link, it can stop the click and explain why. I can ask a follow-up question right in the warning.” |
| 1:58–2:30 | On the secret-paste fixture, click **Copy public test phrase**. Focus the empty field and press Command-V. Keep the warning, empty field, and zero paste count in view. | “A recovery phrase needs a faster check. I’m pasting a public test phrase into this empty box. The extension recognizes its format locally and stops the paste before the page receives it. Muse gets the category for the warning. The phrase itself stays out of the model.” |
| 2:30–3:00 | Show **Pause monitoring** and **For 30 minutes**. End on the avatar beside the guide with a short title card. | “The model runs on this Mac. Chrome sends bounded page text without asking for Screen Recording. Desktop visual checks need the Mac’s permission, and I can pause automatic checks from Muse or Chrome. I can still ask a question while paused. That’s Muse Guard, an on-device companion that can explain what caught its attention.” |
