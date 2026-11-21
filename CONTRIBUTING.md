# Contributing to Damon

Use macOS 15 or later with a Swift 6 toolchain. The contributor checks do not need a Music subscription, Automation permission, or external hardware.

1. Create a topic branch: `git switch -c your-topic`.
2. Reproduce the behavior and add a focused regression test when changing format detection, transport, or alignment.
3. Run `sh Scripts/check.sh` from the repository root. Use `swift test --filter <test-name>` for focused iteration.
4. Share the change with its purpose, test results, and any remaining live test conditions. Keep unrelated edits in separate commits.

If hosted on GitHub, the [macOS workflow](.github/workflows/check.yml) runs the same checks for pushes and pull requests.

## Code map

| Path | Responsibility |
| --- | --- |
| [`Sources/Damon`](Sources/Damon) | Menu bar, preferences, and user-facing diagnostics. |
| [`Sources/DamonPlatform`](Sources/DamonPlatform) | Public macOS interfaces, CLI commands, fixture generation, and device readback. |
| [`Sources/DamonPolicy`](Sources/DamonPolicy) | Testable evidence ranking, rate-write decisions, and verification rules. |
| [`Tests/DamonTests`](Tests/DamonTests) | Regression tests and synthetic format controls. |

## Evidence and reporting

- Keep estimates out of the write path. Review the [confidence model](SPECIFICATION.md#4-confidence-model) before adding a new evidence source. Use public, documented interfaces and permitted UI observations; do not depend on private frameworks or undocumented log messages.
- For a live test report, include the macOS version, build revision, output model and connection type, playback source, expected format, observed format, and the minimal reproduction steps. Distinguish a simulated result, a live device readback, and a digital sample comparison.
- Redact track identifiers, personal file paths, device UIDs, and credentials. Do not commit Music downloads, live recordings, generated app bundles, or signing material. Generate the synthetic fixtures locally as described in the [test plan](PLAN.md#repeatable-live-trial).

Damon contributions use the repository's [GPL-3.0-only license](LICENSE). Submit only work you have the right to license. Keep third-party names, notices, and source attribution with any material you are authorized to redistribute. See [NOTICE](NOTICE) for LosslessSwitcher credit and provenance.
