# Damon · BitStream Manager

A macOS menu bar app and command-line toolkit for observing Apple Music's playback format and testing sample-rate alignment. Damon keeps the source format, the selected device's setting, and bit-perfect playback separate.

**Status: development preview.** The app runs in monitor-only mode on unqualified routes. The lab command demonstrated timed rate changes on an Eitr 2 with known ALAC fixtures; that does not qualify general Apple Music catalog switching or establish bit-perfect playback.

| Display | Meaning |
| --- | --- |
| Green `96k / 24` | Damon verified the source format, for example by matching the currently playing authorized local file to its format header. |
| Amber `≈96k / —` | Music reports a sample rate, but Damon has not established that it describes the active rendition. The bit depth is unknown. Estimates never trigger device writes. |
| Neutral `— / —` | No current source format is available. |

## Build and run

Requires macOS 15 or later, Xcode 16 or later with its command-line tools selected, and Swift 6 or later. Music is needed for live playback tests, not the automated test suite. A DAC is optional for monitoring and required only for relevant hardware trials.

```sh
sh Scripts/check.sh
```

This runs the Swift tests and builds and verifies an ad-hoc-signed development bundle at `dist/Damon.app`. Open it from Finder and enable **Monitor Apple Music** in the menu bar. macOS will ask you to authorize Music Automation. To verify a local source format, choose an audio file or a dedicated fixture folder under **Choose Authorized Local Audio**. For reproducible input, generate the synthetic kit:

```sh
damon=./dist/Damon.app/Contents/MacOS/Damon
"$damon" --make-qualification-kit dist/QualificationKit
"$damon" devices
"$damon" status
"$damon" probe-format
```

The kit command requires a new destination. Run `"$damon" --help` for the full command list. `devices`, `status`, and `probe-format` do not change playback or audio settings. The `playback` and fixture trial commands can change what Music is playing. The separate `test-switch` lab command can change device settings and requires explicit opt-in.

## Project guide

- [Specification](SPECIFICATION.md): observable behavior, confidence model, privacy boundaries, and release criteria.
- [Development and test plan](PLAN.md): CLI cookbook, lab procedures, measured results, and outstanding qualification gates.
- [Contributing](CONTRIBUTING.md): development workflow and what to include in a report or proposed change.

## License and credits

Damon is licensed under [GNU GPL v3 only](LICENSE) (`GPL-3.0-only`). It is a separate clean-room project inspired by [LosslessSwitcher 3.0-beta1](https://github.com/vincentneo/LosslessSwitcher/releases/tag/3.0-beta1), by **Vincent Neo and the LosslessSwitcher contributors**. See [NOTICE](NOTICE) for the exact upstream revision and license. Damon is not affiliated with Apple or the LosslessSwitcher project.
