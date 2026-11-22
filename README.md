# RateCue

**Playback format monitor for Apple Music on macOS.** RateCue is a menu bar app and command-line toolkit for observing playback format and testing sample-rate alignment. It keeps the source format, the selected device's setting, and bit-perfect playback separate.

**Status: development preview.** The packaged build has no qualified output configurations or calibrated sensor profiles. It cannot automatically switch catalog playback. A controlled Eitr 2 lab trial demonstrated rate changes with known local ALAC fixtures; it did not establish general catalog switching or bit-perfect playback.

## What the display means

| Display | Meaning |
| --- | --- |
| Green `96k / 24` | RateCue accepted qualified source-format evidence, currently the authorized local file header when it agrees with Music's reported track rate. This does not verify output samples. |
| Amber `≈96k / —` | Music reports a sample rate, but RateCue has not established that it describes the active rendition. The bit depth is unknown. Estimates never trigger device writes. |
| Amber `≈96k / 24` | A Music Lossless-panel snapshot explicitly showed 24-bit depth. It remains unverified and clears on playback, route, or reported-rate changes. |
| Neutral `— / —` | No current source format is available. |

The menu's **Status** describes alignment using qualified evidence. It can say **Unknown Format** while an amber estimate is visible. Neither a device's configured rate nor a DAC LED establishes source bit depth. No display color proves bit-perfect playback.

## Build and run

Requires macOS 15 or later, Xcode 16 or later with its command-line tools selected, and Swift 6 or later. Music is needed for live playback tests, not the automated test suite. A DAC is optional for monitoring and required only for relevant hardware trials.

```sh
sh Scripts/check.sh
```

This validates the packaging plists, runs the Swift tests, then builds and verifies `dist/RateCue.app`. The default signature is ad hoc; setting `DAMON_SIGN_IDENTITY` selects a signing identity instead. The development build is not sandboxed or notarized. Rebuilding replaces the bundled executable and may require renewed macOS permissions. Quit the old Damon or RateCue app before opening the rebuilt bundle. The bundle identifier (`org.damon.BitStreamManager`) and CLI executable name (`Damon`) remain unchanged for compatibility.

Open RateCue from Finder, start Music, and enable **Monitor Apple Music** in the menu bar. Handle the macOS Automation prompt if shown. Select a preferred output under **Select Output Device**; RateCue remembers its UID but does not change the system output route. For local-file source-format evidence, choose an audio file or a dedicated fixture folder under **Choose Authorized Local Audio**.

## Music panel estimates

For a manual estimate, open Music's Lossless panel on the current track and choose **Read Open Music Lossless Panel… → Display Estimate**. Alternatively, choose **Read Fresh Music Lossless Panel…**, then manually open the badge when RateCue prompts you. The timed fresh-panel workflow has timed out in a live trial. Both manual checks only read the interface. An open panel can retain the previous track's format, and even a newly opened panel is not proven to describe the delivered rendition.

For experimental automatic estimates, enable **Automatically Read Music Panel (Experimental)**. Leave Music's Now Playing view available with its Lossless panel closed, and switch away from Music. RateCue attempts a read on playback, route, or reported-rate changes and after Music loses focus; it may open and close the panel. It clears the snapshot while Music has focus, skips an already open panel, and can leave the panel open if interrupted. Turning off monitoring or automatic panel reading cancels an in-flight automatic read. Failed checks appear under **Automatic depth** or **Logs**; toggle the feature off and on to retry the current track.

Panel reading requires Accessibility access and a recognizable Music Now Playing layout and ALAC format text. It may fail with other layouts or localizations. If depth is omitted, ambiguous, or conflicts with Music's track rate, RateCue leaves it unknown. Panel estimates stay amber and never authorize device changes. Live automatic snapshots have been displayed, but same-rate 16/24-bit attribution has not been independently qualified.

Use **Accessibility Access…** to check or request access for the running build. In **System Settings → Privacy & Security**, the setting is called **Device Control and Data Access** on the test Mac; other macOS versions may call it **Accessibility**. The app can read Music's interface, and the optional automatic reader also interacts with its panel.

## Command line

The bundled executable is also a CLI:

```sh
ratecue=./dist/RateCue.app/Contents/MacOS/Damon
"$ratecue" --version
"$ratecue" --help
"$ratecue" devices
"$ratecue" status
"$ratecue" probe-format
```

| Command | Purpose and effects |
| --- | --- |
| `devices`, `--diagnose` | List output capabilities; `devices` returns JSON. Neither changes audio settings. |
| `config show`, `config set ...` | Read or change RateCue preferences, not the system output route. The experimental panel option is set in the menu. |
| `authorize-music` | Explicitly request Music Automation permission for the CLI launcher. Music must already be running. |
| `status`, `check --rate <Hz> --depth <bits> [--device <uid-or-name>]` | Read a fresh qualified source and route observation. Amber menu estimates are not included. `check` returns 0 for a match, 1 for mismatch or unavailable evidence, and 2 for invalid invocation. |
| `probe-format [--panel\|--fresh-panel]` | Read unqualified Music evidence without changing playback or the device. `--panel` reads an open panel; `--fresh-panel` waits for the user to open it. |
| `playback <play\|pause\|next>` | Send a Music playback command. |
| `--make-qualification-kit <new-folder>`, `--make-fixtures <new-folder>` | Generate synthetic audio files in a new directory. The qualification kit also compares each ALAC file with its PCM reference. |
| `test-fixture --kit <folder> [--device <uid-or-name>] [--allow-interrupt]` | Play and check a known local fixture. It can alter Music's playback and queue but does not write the DAC rate. |
| `test-switch --kit <folder> --device <uid-or-name> --allow-rate-write` | Play fixtures and change the selected device rate in an explicitly authorized hardware trial. It attempts, but cannot guarantee, a guarded return to baseline. |
| `--compare-pcm <reference> <candidate> [--offset-frames <N>]` | Compare complete stereo sample windows offline without opening Music or an audio device. |

For reproducible local input, generate the kit in a **new** directory:

```sh
"$ratecue" --make-qualification-kit dist/QualificationKit
"$ratecue" --compare-pcm \
  dist/QualificationKit/PCM/Damon-96000Hz-24bit.wav \
  dist/QualificationKit/ALAC/Damon-96000Hz-24bit.m4a
```

See the [test plan](PLAN.md#cli-configuration-and-tests) for configuration syntax, permission setup, trial preconditions, exit codes, and examples. CLI device and configuration output can contain device UIDs or local paths; redact it before sharing.

## Troubleshooting

- **Music Automation denied:** grant access under **Privacy & Security → Automation**. The bundled app and terminal-launched CLI may require separate grants; `authorize-music` requests access for the CLI.
- **Accessibility enabled but RateCue reports denied:** check **Accessibility Access…** for the running build. Ad-hoc rebuilds may require removing and re-adding this exact `RateCue.app` in the relevant Privacy & Security page; handle system authentication yourself.
- **Automatic depth waits or shows `—`:** Music must be playing with Now Playing available and its Lossless panel closed. With the experiment enabled, the snapshot is deliberately hidden while Music is active. Check **Automatic depth** and **Logs** for failures.
- **Preferred device unavailable or route unconfirmed:** reconnect or select the intended device and check Music's actual output. RateCue does not silently select a replacement or reroute audio.
- **Sensors unavailable:** camera and microphone verification requires a valid calibrated profile and separate permission; the packaged profile list is empty.

Use **Copy Diagnostics** for a status summary designed to omit track titles, paths, and device identifiers. **Qualification Snapshot…** can copy or save a separate JSON report of qualified source evidence and output names; it does not include amber estimates. Review reports and system error text for sensitive information before sharing. **Check for Updates…** is a placeholder; no update service is configured.

## Versions and development

The app and bundled CLI use `CFBundleShortVersionString` and `CFBundleVersion` in [`Packaging/Info.plist`](Packaging/Info.plist). About and `"$ratecue" --version` read the same values. Update both deliberately for a release; the build scripts do not increment them and have no independent version numbers. Script changes are tracked with the project revision.

The menu's **About RateCue**, **Help**, and **Credits** entries show the installed version and build, usage and build guidance, and project attribution.

## Project guide

- [Specification](SPECIFICATION.md): observable behavior, confidence model, privacy boundaries, and release criteria.
- [Development and test plan](PLAN.md): CLI cookbook, lab procedures, measured results, and outstanding qualification gates.
- [Contributing](CONTRIBUTING.md): development workflow and what to include in a report or proposed change.

## License and credits

RateCue is licensed under [GNU GPL v3 only](LICENSE) (`GPL-3.0-only`). It is a separate clean-room project inspired by [LosslessSwitcher 3.0-beta1](https://github.com/vincentneo/LosslessSwitcher/releases/tag/3.0-beta1), by **Vincent Neo and the LosslessSwitcher contributors**. See [NOTICE](NOTICE) for the exact upstream revision and license. RateCue is not affiliated with Apple or the LosslessSwitcher project.
