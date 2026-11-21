# Damon: Development and test plan

The [clean-room specification](./SPECIFICATION.md) defines what users can observe and the release thresholds. This document proposes how to build and test that behavior. Candidate macOS APIs are not proof of runtime support.

## Development plan

### 1. Establish what macOS exposes

Build a capability matrix for the intended signed build, preferring the sandbox where practical. Record the macOS version, playback type, documented evidence source, route, device, and any permission required. Test whether the build can:

- Observe playback state and identify each playback instance, including repeat and rendition changes.
- Establish the sample rate and, separately, the bit depth of the actual rendition before output conversion.
- Identify the route used by Music rather than assume it is the system default. [`AudioHardwareProcess.devices`](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/devices), documented for macOS 15 and later, is a route-attribution candidate.
- Enumerate devices and supported rates, persist stable device identity, and write and reread the selected device's nominal rate.

[`Song.audioVariants`](https://developer.apple.com/documentation/musickit/song/audiovariants) describes available variants, not the currently playing rendition. [`SystemMusicPlayer`](https://developer.apple.com/documentation/musickit/systemmusicplayer) does not list native macOS availability. Test any documented, permissioned playback or read-only UI surface against independently known formats before admitting it into the confidence model.

**Exit gate:** Enable automatic switching only for configurations on which qualified source rate, Music route, and device writes are demonstrated through documented interfaces. A configuration without that evidence is monitor-only. Bit depth can remain unknown without blocking a qualified rate.

### 2. Build the monitor and replay the policy

Keep playback and device observers separate from confidence resolution, device writes, and UI. Normalize observations with monotonic timestamps, provenance, and playback and route identity. Keep state transitions testable with replayable traces so policy tests do not depend on Apple Music accounts, devices, or permissions. Add preferences, menu states, and diagnostic logging before enabling writes. Use operating system logs only for troubleshooting.

**Exit gate:** The monitor reports source and output separately, survives restarts and disconnects, and produces deterministic results for the same set of current observations.

### 3. Qualify automatic alignment

Start with a single confirmed wired output carrying stereo lossless playback. Qualify USB and Thunderbolt separately. Keep Bluetooth, AirPlay, aggregate or multi-output devices, and ambiguous overlapping playback read-only until individually qualified. Serialize writes and verify with documented property notifications and readback. Apple notes that [`AudioObjectSetPropertyData`](https://developer.apple.com/documentation/coreaudio/audioobjectsetpropertydata(_:_:_:_:_:_:)) can apply changes asynchronously.

**Exit gate:** Supported hardware meets the write, timing, recovery, and no-unintended-write tests. Publish the exact macOS and device configurations that pass.

### 4. Add optional hardware verification

Calibrate LED regions of interest, lock indication, rate mappings, and relay signatures and timing per DAC profile. Test the classifiers on held-out evidence. A DAC without a distinguishable rate indicator or reliable relay signature can still use rate alignment, but cannot earn full transition verification. Keep the digital sample-integrity lab test separate from both sensors.

**Exit gate:** Hardware statuses follow the [Confidence Model](./SPECIFICATION.md#4-confidence-model), including when permissions are denied or signals disagree. The support matrix describes what each DAC profile can verify.

## Test plan

### Environments and test oracles

- Run deterministic policy replay without live Apple Music or DACs. Follow with a signed release build on the oldest and newest supported macOS versions on Apple Silicon.
- Use a qualified USB DAC, a qualified Thunderbolt configuration, and a rate-limited device. Exercise the sandboxed build if it is the intended distribution build, including permission denial and revocation.
- Use authorized ALAC fixtures with independently known formats: 44.1 kHz at both 16 and 24 bits; 48, 88.2, 96, 176.4, and 192 kHz at 24 bits. For a catalog track without independent active-rendition ground truth, mark the result unverified; do not use Damon's own observation as the oracle.
- Use device readback as the alignment oracle and independently labeled hardware trials as the LED and relay oracle. For bit integrity, use a trusted PCM reference and a capture method that does not alter the target digital path.

### Test cases

| ID | Area | Cases and expected results |
| --- | --- | --- |
| T01 | Evidence ranking | Replay Core Audio source vs. contradictory track metadata, nominal device rate vs. track metadata, and metadata vs. contradictory LED evidence. The higher qualified source observation wins; a contradictory LED fails verification without changing the target. |
| T02 | Missing, ambiguous, and stale evidence | Replay conflicting current values at one tier, missing depth, incompatible rate/depth observations, catalog-only evidence, sensor-only evidence, and late events from old playback or route generations. Reorder the same qualifying observations and assert the same final decision. Unknown rates cause zero writes; a qualified rate can still be written with unknown depth. |
| T03 | Playback and normal switching | Test start, pause/resume, stop, next/previous, queue progression, repeat, a rendition change on the same track, and rapid skips. A qualified rate mismatch writes only the preferred active device; an already-matching rate or depth-only change causes no rate write. Paused and stopped playback do not initiate writes. |
| T04 | Write failures and drift | Test unsupported rates, a read-only device, denied writes, and a successful set that never reads back. Assert the exact number of write calls and target device, at most one eligible retry within the deadline, and no success label without matching readback. External changes after alignment surface as drift rather than a rewrite loop. |
| T05 | Device lifecycle and races | Reboot, sleep/wake, power-cycle, unplug during a write, re-enumerate, and change the route with confirmation pending. Test two same-named devices and a changed stable identifier. Recovery requires the original identity and a confirmed route; no fallback writes or stale success states are allowed. A changed identifier requires reselection. |
| T06 | Hardware verification | Test correct lock and click, a credible rate mismatch, stale or occluded LEDs, clicks before write or after the correlation window, unrelated transients, no relay, and permissions denied or revoked. Test confidence equal to and greater than 0.95. Missing evidence cannot produce **Transition verified**; neither missing nor contradictory evidence triggers a write. Measure classifier accuracy against held-out labeled trials. |
| T07 | Digital sample integrity | Compare reference PCM with a non-altering digital capture from the tested path. Introduce gain changes, mixing, and resampling back to the expected output rate as negative controls. Rate confirmation may still pass, but sample comparison must fail. Do not extrapolate a local test to a catalog session. |
| T08 | Menu, settings, and privacy | Test all four display-toggle combinations, unknown fields, warning and recovery states, persisted preferences, launch at login, check for updates, and quit. Verify that sensor permissions are requested only for enabled features and raw media is not persisted. |
| T09 | Performance | Measure detection, write/readback, menu update, verification, idle/playback CPU and memory, and transition CPU against every threshold in the [specification](./SPECIFICATION.md#6-release-acceptance-criteria). Report sensor-on and sensor-off runs separately. |

### Measurement and release reporting

Use a monotonic clock for playback boundaries, evidence acceptance, alignment start, readback, menu publication, and verification completion. Timestamp playback independently of Damon's observer. Measure the 2-second overall alignment deadline directly from the playback boundary; do not add the detection and write budgets. For verification, measure from confirmed readback. Log transient CPU peaks separately from transition-window averages.

Report the count of independently labeled supported trials, wrong formats, unknowns, misses, deadline failures, and superseded trials. The wrong-format ratio uses independently labeled supported transitions as its denominator; a missed positive trial still fails the detection gate. Report sensor confidence and measured classification accuracy separately.

Publish three distinct outcomes: where automatic alignment passed, where Damon remains monitor-only, and exactly which paths and assets passed a digital sample comparison. Do not market rate matching or hardware confirmation as proof of bit-perfect playback.

## Development build and qualification status

From the project directory:

```sh
swift test
sh Packaging/build-app.sh
dist/Damon.app/Contents/MacOS/Damon --diagnose
```

The build script compiles the release target, creates `dist/Damon.app`, and verifies its signature. By default it uses an ad-hoc development signature. Set `DAMON_SIGN_IDENTITY` to a suitable signing identity for a signed qualification build. The current build is not sandboxed or notarized. The `--diagnose` command only reads Core Audio output capabilities. It does not send Music events, start either sensor, or change audio settings.

### CLI configuration and tests

From the project directory, use the bundled executable without launching the menu app:

```sh
damon=./dist/Damon.app/Contents/MacOS/Damon
"$damon" --help
"$damon" devices
"$damon" config show
"$damon" config set --device "Eitr 2" --auto-switch off --monitor-music on \
  --local-audio dist/QualificationKit/ALAC
```

`config set` changes only Damon's saved preferences. The menu app uses the same preferences and picks up CLI changes on its next observation. Prefer the UID from `devices` if output names are ambiguous. `--device none` clears the preferred output, and `--clear-local-audio` removes the audio-file authorization. Use `--show-rate` and `--show-depth` to control display fields. Enabling `--auto-switch` does not qualify a route or override any write guard.

With Music already running, use `"$damon" authorize-music` to explicitly request macOS Automation permission for the CLI launcher. macOS may attribute CLI access to the terminal app separately from the menu app. No other command requests permission. To observe an existing Music session without affecting playback, run:

```sh
"$damon" status
"$damon" check --rate 96000 --depth 24 --device "Eitr 2"
```

`check` uses the preferred device if `--device` is omitted. Add `--device-rate 44100` to assert the nominal device rate separately from the source. Output is JSON; an unknown format, stopped playback, or missing/ambiguous route fails the check rather than guessing. Exit codes: `0` all assertions matched, `1` mismatch or unavailable evidence, `2` invalid arguments. A passing observation is not a switching or bit-perfect test.

### Catalog format research

Catalog format detection is the current priority. Keep catalog switching disabled until the source rate is tied to the rendition actually playing.

With an Apple Music catalog track playing, use `"$damon" probe-format` to read Music's published `sample rate` property for the active track. Add `--panel` to read the already open Now Playing Lossless panel when Accessibility permission is available. The probe distinguishes a missing or zero property from an Apple event error. It rejects a result if the track changed or playback stopped during observation. It does not log track identifiers or paths, change playback, open the panel, or treat either reading as a switching input.

A nonzero property is not enough: on the same catalog track, the evidence must track the actual rendition rather than the catalog/master format or the selected quality preference. Check it across independently established rendition changes. The device's nominal rate is not a source-format reference, and Music's scripting dictionary specifies bitrate, not source bit depth.

The menu bar displays an unverified rate from Music in amber with an approximation marker; the menu and tooltip identify it as unverified. Qualified source formats appear in green. The diagnostic and alignment paths still keep the estimate out of verified source-format fields.

In one live catalog trial, the scripting property returned 96,000 Hz and the user read 24-bit / 96 kHz in the visible panel. A lower streaming quality setting and a Lossless-off attempt did not produce a different panel reading; the scripting property also stayed at 96,000 Hz. This is agreement on one reported format, not evidence of an active rendition change. Repeat with an undownloaded catalog track and verify that the two plays actually use different renditions before interpreting the result. Bit depth is not available from the scripting property.

In a separate diagnostic check, the visible Lossless panel showed `44.1 kHz ALAC` without a depth. Recent local Music logs contained explicit 16-bit and 24-bit rendition reports at that same rate, as well as zero-valued depth in some Now Playing events. This is evidence that Music reports depth internally, but not a documented guarantee that a given log event belongs to the active rendition. Do not consume these log messages as a format provider. Use the known 44.1 kHz 16-bit and 24-bit fixtures as a same-rate control when evaluating any documented or explicitly exposed source.

For repeatable transport checks, open Music with a test queue and use explicit CLI commands:

```sh
"$damon" playback pause
"$damon" playback play
"$damon" playback next && "$damon" probe-format
```

These commands require Music Automation permission, but do not prompt for it or change the user's Music settings. They return JSON with the observed state, whether a command was sent, and whether Music confirmed the change. `next` only succeeds when Music reports a different current track; prepare a queue with a distinct following track. An unsuccessful confirmation is not retried, so an uncertain Next request cannot skip an additional track. Exit codes: `0` confirmed, `1` unavailable or unconfirmed, `2` invalid command. Transport confirmation does not qualify the format reported by the separate probe.

The live transport smoke test confirmed pause, resume, and one advance to a distinct Music track. The probe reported 44.1 kHz before and after the advance; this run verified transport, not a change in source format.

### Repeatable live trial

With Music running, Automation authorized, and Auto Switch off, run:

```sh
damon=./dist/Damon.app/Contents/MacOS/Damon
"$damon" test-fixture --kit dist/QualificationKit --device "Eitr 2"
```

The command generates the kit if the requested folder does not exist, checks the exact 96 kHz / 24-bit ALAC output against its PCM reference, and asks Music to play that file once. It checks the exact active file, source format, and single expected route in a 10-second observation window. It does not change the DAC rate, Music settings, or Damon's saved preferences. It refuses to replace active or paused playback unless `--allow-interrupt` is passed. Music may change its playback queue or location when opening a local file. Damon does not restore the previous queue or treat a copied file outside the trial scope as the original. A passing observation does not verify digital samples on the DAC link.

To generate the kit separately, use a **new** destination. The kit includes a JSON manifest with expected rates, bit depths, and frame counts. Both 44.1 kHz files and the 96 kHz file are 60 seconds long; the other four are 12 seconds each.

```sh
dist/Damon.app/Contents/MacOS/Damon --make-qualification-kit dist/QualificationKit
afinfo dist/QualificationKit/ALAC/Damon-96000Hz-24bit.m4a
```

1. Open Damon and Music, then enable **Monitor Apple Music** in Damon's menu. Handle the read-only Automation request in macOS. Leave Auto Switch and both sensors off for this trial.
2. Select the test DAC in Damon without changing the output route. Use **Choose Authorized Local Audio…** to select the kit's `ALAC` folder. Play the 96 kHz fixture in Music. If Music copies the fixture on import, use **Show in Finder** on the Music track and authorize just that copied file in Damon; do not authorize the whole Music library.
3. While the fixture plays, open **Qualification Snapshot…** and use **Save JSON…** (or **Copy** for a short text readout). Verify the snapshot reports both the expected rate and bit depth and the actual Music output. Repeat with one rate change and then the 44.1 kHz 16/24-bit pair. The device's nominal rate is recorded separately and is expected to stay unchanged in this trial. The export omits track titles, file paths, and persistent identifiers. Missing measurements are omitted, not recorded as zero.
4. For a catalog observation, manually open the **Lossless** badge in Music's Now Playing view. Damon's **Read Open Music Lossless Panel…** is a one-shot diagnostic, requires Accessibility permission, and never opens or controls the panel. On the test host the open panel exposed `44.1 kHz ALAC` with no explicit bit depth. That value is not a switching input. Before qualifying it, test whether it follows independently known rendition changes, whether it stays visible, and whether missing or stale content is rejected without taking focus.

Damon accepts the stereo integer PCM or ALAC source header only when it agrees with Music's published track sample rate. The header tests alone do not qualify the live playback path. Damon never substitutes catalog availability, bitrate, or the output device's format for the current rendition.

### Timed hardware-switch trial

This separate lab command makes temporary Core Audio writes. Stop Music first, leave regular Auto Switch off, and use an externally connected device already set to 44.1 kHz. Do not run it on a shared output carrying active audio from another app.

```sh
dist/Damon.app/Contents/MacOS/Damon test-switch \
  --kit dist/QualificationKit --device "Eitr 2" --allow-rate-write
```

The command validates the fixture files, tests `44.1 -> 96 -> 44.1 kHz`, and then plays the 44.1 kHz / 24-bit fixture to check that a depth-only change causes zero rate writes. It uses the production alignment state machine and guarded Core Audio write path. It requires the exact source, unchanged device identity, and a single confirmed Music route before a write. It refuses to write if another active Core Audio output process uses that device; it does not take an exclusive hardware lock. It does not enable regular Auto Switch or change device selection. If a trial fails, recovery uses the baseline fixture only when the prior write's effect and the target endpoint can be confirmed; otherwise check `restored` and `finalRateHz` in the report before continuing. The final fixture plays once.

The JSON report separates source detection, write-request-to-readback latency, overall playback-request-to-readback latency, and post-write playback/route confirmation. The harness polls Core Audio directly rather than waiting for a new Music metadata snapshot to time readback. It requires readback within 500 ms of alignment and 2 seconds of the explicit fixture request. Music's route may temporarily be unavailable during reconfiguration. The harness requires the same fixture and route to be confirmed again within 2 seconds of readback and does not treat a different confirmed track or route as temporary. The fixture request precedes playback, so the overall timing covers these controlled starts, not an independently timestamped digital playback boundary or natural catalog transitions.

**Observed Eitr 2 pass on the Apple Silicon test host:**

| Fixture transition | Source detected after playback request | Alignment request to readback | Playback request to readback | Writes |
| --- | ---: | ---: | ---: | ---: |
| 44.1 to 96 kHz / 24-bit | 794.618 ms | 278.654 ms | 1,073.272 ms | 1 |
| 96 to 44.1 kHz / 16-bit | 573.065 ms | 277.622 ms | 850.688 ms | 1 |
| 44.1 kHz / 16-bit to 44.1 kHz / 24-bit | 607.467 ms | Not applicable | 607.467 ms | 0 |

The same fixture and route were reconfirmed 667.171 ms and 663.813 ms after the two writes. The device finished at its original 44.1 kHz, with regular Auto Switch off. Earlier runs did not pass: the first did not observe readback in time, and the second observed both rates in time but did not reconfirm the route immediately. Regression cases cover slow Music metadata, third-party route ambiguity, delayed readback, and temporary unavailability of Music's route.

The menu app and trial now share the direct readback and continuity checks. The menu app performs the write and readback off the main thread, rechecks playback and preferences before writing, and only publishes a confirmed transition after rechecking the same source and route. A stale result cannot become a verified transition. Regression tests cover changed tracks, rerouted playback, and settings updated during verification. The live measurements above are from the lab command, not the menu app; the development bundle still has no enabled qualification profiles.

### Compare a digital capture with reference PCM

The generator validates each ALAC fixture by decoding and comparing every sample against the corresponding WAV. For a live integrity test, use a separate digital recorder or analyzer that preserves the target link's native samples. Compare its result offline:

```sh
dist/Damon.app/Contents/MacOS/Damon --compare-pcm \
  dist/QualificationKit/PCM/Damon-96000Hz-24bit.wav capture.wav
```

This compares the full stereo reference at the native rate with no resampling, gain change, or channel remapping. Zero-padded integer representations can match. By default the files must also have the same length. If a capture includes pre-roll or trailing data, add `--offset-frames N` using a known, nonnegative capture start frame; the full reference must still fit and match. A sample mismatch reports the first zero-based reference frame and one-based channel. Exit codes: `0` exact match, `1` mismatch, `2` invalid input or read failure. No audio device or Music session is opened by this command. A file-to-file fixture check validates the fixture and tool, not live playback or the capture hardware.

Qualification so far:

| Gate | Evidence and status |
| --- | --- |
| Source-format and decision replay | Swift tests cover CLI preference updates, qualification checks, changed samples, short capture windows, and lossless integer padding. Every generated ALAC fixture decodes to the exact matching WAV samples. Apple Event specifier construction passed; this does not establish live Music Automation behavior. |
| Apple Music catalog formats | A manually opened Lossless panel exposed an ALAC rate but no bit depth. The closed badge exposed only the quality label. No continuously available, rendition-bound provider has been established. Catalog auto-switching is not supported by this build. |
| Live route and writes | The read-only local trial verified the exact 96 kHz / 24-bit fixture and Eitr 2 Music route. A separate explicitly authorized lab trial passed with two timed writes and zero writes for a depth-only change. It restored the original rate. This qualifies only that controlled hardware trial; regular Auto Switch remains disabled on unqualified routes. No Thunderbolt audio device was present. |
| Profile-based sensors | The app includes opt-in camera and microphone adapters and replay-tested correlation rules. No calibrated profile or held-out live sensor trials exist yet. Capture remains disabled without a profile. |
| Launch and idle spot check | The ad-hoc-signed app launched on the Apple Silicon test host. A short idle sample showed 0.0–0.2% CPU and 18 MB resident memory. The user reported unknown source fields while Music was playing, but the Automation and route status were not confirmed. |
| Live digital capture | The test host exposes the Eitr 2 as an output and a mono USB input at 48 kHz. Neither establishes a verified stereo digital capture path from the Eitr 2. Use an independent digital recorder or analyzer and the existing PCM comparison command before making a sample-integrity claim. |
| Release | Release-wide switching deadlines and accuracy, reconnect and login behavior, sustained CPU/RSS limits in all modes, live digital capture comparison, and a production update endpoint are not yet qualified. |

Keep `DamonQualifiedLocalOutputs` in [the bundle plist](./Packaging/Info.plist) empty until an exact `macOS` version and `deviceUID` have passed live scoped stereo-lossless switching tests, including races, other playback, and readback deadlines. Do not use this field to qualify catalog playback. Keep `DamonSensorProfiles` empty until a profile tied to the preferred device, specific capture devices, and measured LED and click classifier results has passed held-out tests. Neither kind of profile is an assertion of digital sample integrity.
