# Install and test the Offload test build on your Mac

This is the **test build**: built by CI from one commit, signed ad hoc, not notarized, no automatic updates. Its
bundle id is `ai.offload.mac.dev`, so it never mixes with the release app. The notarized build has its own guide:
[DEPLOYMENT section 5](../../../docs/DEPLOYMENT.md#5-install-and-test-guide).

Needs a Mac with Apple silicon and macOS 14 or later.

## 1. Download

1. Open the repository on GitHub, then **Actions**, then the **mac-artifact** workflow.
2. Click the newest green run for the branch you want to test.
3. Under **Artifacts**, download `Offload-mac-<commit>`. GitHub always wraps an artifact in a zip:
   - Safari unzips it for you, into a folder holding `Offload-mac-<commit>.zip` and this guide.
   - Other browsers save `Offload-mac-<commit>.zip` with a zip of the same name inside. Double-click the outer one
     first to get the folder.
4. Double-click the inner `Offload-mac-<commit>.zip`. Move the `Offload.app` it makes into **Applications**.

Builds of a pull request carry GitHub's merge commit for that pull request, not the pull request's own last commit.
The run's summary page names both.

Open it from Applications, not from Downloads: macOS moves apps it does not trust to a hidden temporary place, and
permissions granted there do not stick.

## 2. Open it the first time

The build is signed ad hoc, not by an Apple Developer ID yet, so macOS blocks the first open. That is expected.

- **macOS 15 and later**: open Offload once and close the warning. Then System Settings, Privacy & Security,
  scroll to Security, click **Open Anyway** next to the Offload line, confirm, and open Offload again. Right-click
  Open no longer gets past this warning on macOS 15.
- **macOS 14**: right-click `Offload.app` in Applications, choose **Open**, then **Open** again. If there is no Open
  button, use **Open Anyway** as above.
- Or, on any version, in Terminal: `xattr -dr com.apple.quarantine /Applications/Offload.app`

Check which build you have:

```
/Applications/Offload.app/Contents/MacOS/Offload --version
```

It prints `Offload <version> (<build>) <commit> ai.offload.mac.dev`. Mention that line in every report.

## 3. Permissions

Setup asks for two switches in System Settings, Privacy & Security:

- **Accessibility**: to read window titles and the words in them, not what you type. Needed for good results.
- **Screen Recording**: to read apps that don't share their text. Recommended.

Each row ticks on its own within about 2 seconds of flipping the switch. After Screen Recording, Offload asks to quit
and reopen; it comes back on the same screen. You can continue with either one missing. Offload never asks for Input
Monitoring.

An ad hoc build has no stable signing identity, so each new download is a new app to macOS: you may need to turn
both switches off and on again after installing a newer build. Reset them with the commands in section 6.

## 4. What to expect

- A small mark in the menu bar, and the setup window. Setup takes about five minutes and every step can be skipped.
- Watching starts with a later build. In this one the "last 10 minutes" screen has nothing to count, and the last
  setup screen says your choices are saved on this Mac. Nothing is recorded and nothing is sent.
- Sign-in and sending are not in this build yet. Setup says so and offers to keep Offload on this Mac (Local mode).
- Never watch shows 1Password, banking sites and private windows as always excluded, and you can add apps and
  sites. The exclusions take effect when capture lands.
- Today opens as an honest empty state. It fills once capture and upload land in later builds.
- To see setup again: `/Applications/Offload.app/Contents/MacOS/Offload --onboarding`, or a single screen with
  `--onboarding-screen <n>` (0 to 13).

## 5. Send logs back

```
mkdir -p ~/Desktop/offload-logs
/Applications/Offload.app/Contents/MacOS/Offload --version > ~/Desktop/offload-logs/version.txt
log show --predicate 'process == "Offload"' --last 1h > ~/Desktop/offload-logs/system.txt
cd ~/Desktop && zip -r offload-logs.zip offload-logs
```

Send `offload-logs.zip` with a few lines on what you did and what you saw. Screenshots of a screen that looks wrong
help. Check `system.txt` before sending; Offload logs no screen text, but other apps' lines can show up in a
system log. A diagnostic file with no content at all comes with the notarized build (DEPLOYMENT section 5).

## 6. Uninstall and reset

Quit Offload from the menu bar mark, drag it from Applications to the Bin, then in Terminal:

```
defaults delete ai.offload.mac.dev
rm -rf ~/Library/Application\ Support/ai.offload.mac.dev ~/Library/Caches/ai.offload.mac.dev
tccutil reset Accessibility ai.offload.mac.dev
tccutil reset ScreenCapture ai.offload.mac.dev
```

`defaults delete` forgets setup progress, so the next open starts setup from the first screen. The folders are named
after the bundle id ([DEPLOYMENT section 2](../../../docs/DEPLOYMENT.md#2-identity-bundle-id-team-id-and-permissions));
this build writes nothing there yet, later builds keep the local buffer there. The two `tccutil` lines remove the
permission rows. Nothing of this build is stored in the cloud.

## 7. Known limits of this build

- Not notarized: every new download needs the first-open step in section 2.
- No automatic updates. Download the newest artifact to update. Artifacts are kept for 14 days.
- No sign-in, no upload, no suggested fixes yet.
