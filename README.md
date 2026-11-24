# RateCue

<p align="center">
  <img src="Branding/RateCue-Icon-1024.png" alt="RateCue icon" width="160">
</p>

[![macOS checks](https://github.com/troylefevre65/RateCue/actions/workflows/check.yml/badge.svg)](https://github.com/troylefevre65/RateCue/actions/workflows/check.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**Track what Apple Music reports—and see which parts RateCue can verify.** RateCue is a macOS menu bar app and command-line toolkit for monitoring sample rate and bit depth without confusing source format with the selected DAC setting.

### At a glance

- Observe Apple Music rate changes quickly from the menu bar.
- Correlate Music's Lossless panel and playback evidence with explicit provenance.
- Keep the track format, selected output setting, active route, and bit-perfect status separate.
- Reveal engineering and statistical detail only when opening **Advanced Diagnostics**.
- Reproduce behavior through a CLI designed for repeatable automated checks.

RateCue is for listeners who want trustworthy visibility into lossless playback and for developers or hardware reviewers who need inspectable evidence rather than a single opaque indicator.

**Status: development preview.** The packaged build has no qualified output configurations or calibrated sensor profiles. It cannot automatically switch catalog playback. A controlled Eitr 2 lab trial demonstrated rate changes with known local ALAC fixtures; it did not establish general catalog switching or bit-perfect playback.

## What the display means

| Display | Meaning |
| --- | --- |
| Green `96k / 24` | RateCue accepted qualified source-format evidence, currently the authorized local file header when it agrees with Music's reported track rate. This does not verify output samples. |
| Amber `≈96k / —` | Music reports a sample rate, but RateCue has not established that it describes the active rendition. The bit depth is unknown. Estimates never trigger device writes. |
| Amber `≈96k / 24` | A Music Lossless-panel snapshot explicitly showed 24-bit depth. It remains unverified and clears on playback, route, or reported-rate changes. |
| Neutral `— / —` | No current source format is available. |

Correlated bit depth is a separate amber estimate. It starts from provisional, uncalibrated rate-conditioned priors (44.1 kHz: 70% 16-bit / 30% 24-bit; 88.2/96/176.4 kHz: 30% / 70%; 192 kHz: 5% / 95%; otherwise 50% / 50%), then updates the candidate probabilities with bounded evidence likelihood weights. Music panel and Music log/decoder observations share one independence family, so only the strongest non-conflicting weight from that family is multiplied; duplicate influences remain visible with zero log-odds effect. Accepted observations persist only within the unchanged playback context. Prior-only formats retain their probabilities but always withhold an estimate. A candidate is published only when accepted evidence exists, its posterior is at least 90%, and no conflict exists. These provisional model outputs are not calibrated confidence claims, never qualify source format, and never trigger a device write.

The menu's **Status** describes alignment using qualified evidence. It can say **Unknown Format** while an amber estimate is visible. Neither a device's configured rate nor a DAC LED establishes source bit depth. No display color proves bit-perfect playback.

## Build and run

Requires macOS 15 or later, Xcode 16 or later with its command-line tools selected, and Swift 6 or later. Music is needed for live playback tests, not the automated test suite. A DAC is optional for monitoring and required only for relevant hardware trials.

```sh
sh Scripts/check.sh
```

This validates the packaging plists, runs the Swift tests, then builds and verifies `dist/RateCue.app`. When available, it uses the `RateCue Local Development` code-signing identity so macOS permission grants remain stable across rebuilds; setting `DAMON_SIGN_IDENTITY` selects another identity. On a machine without either identity, it falls back to ad-hoc signing and rebuild permissions may change. The development build is not sandboxed or notarized. Quit the old app before opening the rebuilt bundle. The bundle identifier (`org.damon.BitStreamManager`) remains unchanged for preference compatibility; the CLI executable is named `RateCue`.

Open RateCue from Finder, start Music, and enable **Monitor Apple Music** in the menu bar. Handle the macOS Automation prompt if shown. Select a preferred output under **Select Output Device**; RateCue remembers its UID but does not change the system output route. For local-file source-format evidence, open **Advanced Diagnostics** and choose **Choose Authorized Local Audio**.

## Music panel estimates

For a manual estimate, open Music's Lossless panel on the current track and choose **Music Evidence → Read Open Music Lossless Panel…**. Alternatively, choose **Music Evidence → Read Fresh Music Lossless Panel…**, then manually open the badge when RateCue prompts you. The timed fresh-panel workflow has timed out in a live trial. Both manual checks only read the interface. An open panel can retain the previous track's format, and even a newly opened panel is not proven to describe the delivered rendition.

For experimental automatic estimates, enable **Music Evidence → Automatically Read Music Panel (Experimental)**. Leave Music's Now Playing view available. After playback, route, or reported-rate changes, RateCue opens and reads a closed Lossless panel, or closes and reopens an existing panel to establish freshness, including while Music is active. It restores the open state when a panel was already open. While depth remains unknown, it retries periodically. Existing snapshots remain visible until those changes invalidate them. Turning off monitoring or automatic panel reading cancels an in-flight automatic read, which can leave the panel closed or open during an interrupted interaction. Failed checks appear under **Advanced Diagnostics**.

Panel reading requires Accessibility access and a recognizable Music Now Playing layout and ALAC format text. It may fail with other layouts or localizations. If depth is omitted, ambiguous, or conflicts with Music's track rate, RateCue leaves it unknown. Panel estimates stay amber and never authorize device changes. Live automatic snapshots have been displayed, but same-rate 16/24-bit attribution has not been independently qualified.

Use **Music Evidence → Accessibility Access…** to check or request access for the running build. In **System Settings → Privacy & Security**, the setting is called **Device Control and Data Access** on the test Mac; other macOS versions may call it **Accessibility**. The app can read Music's interface, and the optional automatic reader also interacts with its panel.

## Command line

The bundled executable is also a CLI:

```sh
ratecue=./dist/RateCue.app/Contents/MacOS/RateCue
"$ratecue" --version
"$ratecue" --help
"$ratecue" devices
"$ratecue" status
"$ratecue" menu-status
"$ratecue" probe-format
```

| Command | Purpose and effects |
| --- | --- |
| `devices`, `--diagnose` | List output capabilities; `devices` returns JSON. Neither changes audio settings. |
| `config show`, `config set ...` | Read or change RateCue preferences, not the system output route. The experimental panel option is set in the menu. |
| `authorize-music` | Explicitly request Music Automation permission for the CLI launcher. Music must already be running. |
| `status`, `check --rate <Hz> --depth <bits> [--device <uid-or-name>]` | Read a fresh qualified source and route observation. Amber menu estimates are not included. `check` returns 0 for a match, 1 for mismatch or unavailable evidence, and 2 for invalid invocation. |
| `menu-status` | Read the running menu app's latest title, 16/24-bit posterior probabilities, evidence state, candidate, provenance, conflict/prior flags, and automatic-panel status from a local atomic JSON snapshot. It does not interact with Music or audio hardware. |
| `probe-format [--panel\|--fresh-panel]` | Read unqualified Music evidence without changing playback or the device. `--panel` reads an open panel; `--fresh-panel` waits for the user to open it. |
| `playback <play\|pause\|next>` | Send a Music playback command. |
| `--make-qualification-kit <new-folder>`, `--make-fixtures <new-folder>` | Generate synthetic audio files in a new directory. The qualification kit also compares each ALAC file with its PCM reference. |
| `test-fixture --kit <folder> [--device <uid-or-name>] [--allow-interrupt]` | Play and check a known local fixture. It can alter Music's playback and queue but does not write the DAC rate. |
| `test-switch --kit <folder> --device <uid-or-name> --allow-rate-write` | Play fixtures and change the selected device rate in an explicitly authorized hardware trial. It attempts, but cannot guarantee, a guarded return to baseline. |
| `--compare-pcm <reference> <candidate> [--offset-frames <N>]` | Compare complete stereo sample windows offline without opening Music or an audio device. |

The `menu-status` payload is versioned and reproducible. It includes the schema/model versions, prior percentages, unrounded 24-bit posterior, and ordered contributions—including the rate prior—showing every influence, candidate, strength label, provisional likelihood ratio, and signed log-odds effect. Redundant same-family evidence is retained diagnostically with a zero effect. **Advanced Diagnostics → Copy Diagnostics** renders the same complete contribution list rather than a summary-only subset.

While Music is monitored, RateCue performs one bounded unified-log backfill per playback epoch. It reads current Music/Core Media decoder reports for sample rate and bit depth, with playback-position timing and reported-rate checks; failed reads stop after a retry budget. A pause or idle interval retains the current track's original decoder-lifecycle anchor so resuming does not shift the log query by the paused wall-clock time; a replay from the beginning resets it. The parser is versioned and replay-tested, and accepted log evidence appears as `decoderLog` or `musicLog` with its actual contribution.

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
- **Accessibility enabled but RateCue reports denied:** check **Music Evidence → Accessibility Access…** for the running build. Development builds should use the persistent `RateCue Local Development` signing identity; if a different identity was used, restore that identity before reauthorizing the exact `RateCue.app`.
- **Automatic depth waits or shows `—`:** Music must be playing with Now Playing available. The automatic reader can reopen an open panel or briefly open a closed panel, even while Music is active. Check **Advanced Diagnostics** for failures.
- **Preferred device unavailable or route unconfirmed:** reconnect or select the intended device and check Music's actual output. RateCue does not silently select a replacement or reroute audio.
- **Sensors unavailable:** camera and microphone verification requires a valid calibrated profile and separate permission; the packaged profile list is empty.

Use **Advanced Diagnostics → Copy Diagnostics** for a status summary designed to omit track titles, paths, and device identifiers. **Advanced Diagnostics → Qualification Snapshot…** can copy or save a separate JSON report of qualified source evidence and output names; it does not include amber estimates. Review reports and system error text for sensitive information before sharing. Development builds have no configured updater.

## Versions and development

The app and bundled CLI use `CFBundleShortVersionString` and `CFBundleVersion` in [`Packaging/Info.plist`](Packaging/Info.plist). About and `"$ratecue" --version` read the same values. Update both deliberately for a release; the build scripts do not increment them and have no independent version numbers. Script changes are tracked with the project revision.

The menu's **About RateCue**, **Help**, and **Credits** entries show the installed version and build, usage and build guidance, and project attribution.

## Project guide

- [Specification](SPECIFICATION.md): observable behavior, confidence model, privacy boundaries, and release criteria.
- [Development and test plan](PLAN.md): CLI cookbook, lab procedures, measured results, and outstanding qualification gates.
- [Contributing](CONTRIBUTING.md): development workflow and what to include in a report or proposed change.

## License and credits

RateCue is licensed under [GNU GPL v3 only](LICENSE) (`GPL-3.0-only`). It is a separate clean-room project inspired by [LosslessSwitcher 3.0-beta1](https://github.com/vincentneo/LosslessSwitcher/releases/tag/3.0-beta1), by **Vincent Neo and the LosslessSwitcher contributors**. See [NOTICE](NOTICE) for the exact upstream revision and license. RateCue is not affiliated with Apple or the LosslessSwitcher project.
