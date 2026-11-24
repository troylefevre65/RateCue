# RateCue

**Automatic playback format alignment for Apple Music on macOS**

This clean-room specification defines observable behavior and acceptance criteria. It does not prescribe frameworks, internal modules, or how evidence is collected. See the [development and test plan](./PLAN.md) for implementation guidance and qualification procedures.

These are product requirements and release gates, not a claim that the development preview already satisfies them. Current capabilities and unqualified behavior are recorded in the [README](./README.md) and [test plan](./PLAN.md#development-build-and-qualification-status).

## 1. Scope

RateCue is a lightweight macOS menu bar app. It monitors Apple Music playback and the selected output device, aligns the device's sample rate when it can establish the active rendition's rate, and shows what evidence supports the result. Apple Music is required; Apple Silicon is preferred. Qualify USB and Thunderbolt output configurations separately.

Sample-rate alignment is not proof of bit-perfect playback. The app distinguishes the source format, the configured output rate, the hardware link rate, and digital sample integrity. Automatic alignment is supported only on configurations where documented interfaces establish both the active rendition's rate and Music's actual output route. Otherwise, RateCue is monitor-only.

Non-goals: library management, replacing playback controls, DSP, equalization, upsampling, audio enhancement, and support for other streaming services.

## 2. Menu bar and settings

- Display `44.1k / 16` by default when both source fields are known. The sample-rate and bit-depth toggles work independently (`44.1k` or `16`). Show `—` for an unknown field. If both fields are hidden, retain the icon and status.
- Show a qualified source format in green. When only a Music-reported sample rate is available, show it in amber with `≈` (for example, `≈44.1k / —`) and identify it as unverified in text. Do not guess bit depth or use the estimate for alignment. Green describes source-format evidence, not DAC verification or bit-perfect playback.
- On an explicit user request, an observed freshly opened Music Lossless panel—or an open panel the user confirms was just opened—may supply a bit-depth snapshot in amber. An experimental, separately enabled option may automatically open a closed panel or close and reopen an existing panel, including while Music is active, to establish that the reading was opened for the current check. It restores an existing panel's open state after the read. Warn that panel contents may still be stale. The snapshot is unverified, never used for alignment, and cleared when playback or the output route changes. A panel that omits depth leaves depth unknown.
- The menu distinguishes **Track Format**, **Preferred Device**, and **Active Output**. Output format is never substituted for unknown source format.
- Correlated bit depth is an amber, unverified estimate with separate 16- and 24-bit posterior values and explicit provenance. Before accepted evidence, it uses provisional rate-conditioned priors and withholds a candidate. A discrete candidate requires accepted evidence, at least a 90% model score, and no conflicting evidence. Correlated Music UI and Music log signals count as one independence family. Model scores are not calibrated confidence claims. The estimate is resolved independently from qualified sample-rate evidence, never averaged, and cannot authorize switching.
- Show **Auto Switch Sample Rate** only when a qualified output configuration is available, plus **Select Output Device**, a **Verification** submenu, **Advanced Diagnostics**, **Launch at Login**, and **Quit**. Diagnostic tools, logs, qualification snapshots, and local-fixture controls belong in **Advanced Diagnostics**, not the primary menu. Do not ship an updater command until an update service exists.
- Provide About, Help, and Credits from the menu. About shows the app's bundled version and build and the project credits. Help explains setup, format confidence, and how to build and test.
- Warn when the preferred device is unavailable, the route or rate is unsupported, alignment fails, or the device drifts after alignment. Report unknown or ambiguous source evidence as **Unknown Format**. Distinguish these states from disabled auto-switching and from the verification outcomes below.

## 3. Playback, device selection, and alignment

1. Monitor Music starts, pauses, stops, resumes, next/previous, queue progression, and repeat. Reevaluate when the rendition or output route changes, including when the track ID stays the same. Monitor device presence and configuration even when Music is not playing.
2. Persist the selected device's documented stable identifier. Do not use its name or a transient runtime identifier as its identity. After login, reboot, sleep/wake, DAC power cycling, or re-enumeration, resume management when the same device is available and confirmed as Music's output. A different identifier requires reselection. Never fall back to another device or change the system output route.
3. Change the sample rate only if Auto Switch is enabled, Music is confirmed to be actively playing through the preferred device, and a qualified source rate differs from the current setting. The exact rate must be supported and writable. Do not write for a matching setting, unsupported rate, ambiguous target, or paused, stopped, or unconfirmed playback. An unknown bit depth does not block a qualified rate change. RateCue does not force the device's bit depth.
4. Confirm a change by reading the configured rate back from the same device. A successful write response alone is not confirmation. Retry a transient alignment failure at most once and within the adjustment deadline; recheck the rate, playback state, and route before retrying. If verification sensors fail, retain the current configuration. If another actor changes the device rate after alignment, report the drift instead of repeatedly overriding it.
5. A new playback instance, route or device change, or an applicable preference change invalidates pending results. Never publish an obsolete write's result as current. If the write is already in flight, let it settle and reread the device before acting on the latest eligible state.

Normal flow: **Idle -> Monitoring -> Format Detection -> Device Alignment -> Verification -> Monitoring**. Stop or pause returns to monitoring without writing. Unavailable devices and unresolved errors produce a warning while monitoring continues.

## 4. Confidence Model

This ranking supersedes any earlier detection-tier order for decisions. Collection order does not determine precedence. Evidence must qualify for the particular fact being decided.

| Rank | Source | Qualification and limits |
| --- | --- | --- |
| 1 | Core Audio stream format | A documented observation for the current Apple Music rendition before output conversion. A nominal device rate, mixer or post-conversion stream format, and padded sample width are not evidence of the source format. |
| 2 | Apple Music metadata | A documented value describing the rendition actually playing, not available catalog variants or a user quality preference. A permitted, read-only UI observation qualifies here only if it explicitly describes the field for the active rendition; it does not count as an independent vote. |
| 3 | DAC LED verification | A fresh, stable, calibrated observation of the selected DAC's locked link rate. It cannot establish source rate, bit depth, or sample integrity. |
| 4 | Relay click confirmation | A fresh transient matching the selected DAC's calibrated signature and the timing of the current write. It corroborates a hardware event, not a rate or bit depth. |

### Decision rules

1. Bind observations to the current playback instance and device/route generation. Use monotonic observation times. Reject stale, superseded, or unattributed observations; a newly delivered callback is not necessarily fresh.
2. Resolve rate and bit depth separately. For each field, accept the unique value at the highest qualifying source tier. If that tier contains two conflicting current values, mark the field unknown without falling through. Log a qualified lower-tier disagreement but do not let it override the winner. Do not combine a winning rate with a bit depth reported for an incompatible rate.
3. Only ranks 1 and 2 can establish a write target. A device configured at 48 kHz does not override metadata identifying a 96 kHz active rendition. A qualified 96 kHz source-stream observation does override conflicting 44.1 kHz metadata. An LED and a relay click alone leave the track format unknown and do not authorize a write.
4. Hardware evidence never changes the target or triggers another write. Report the following outcomes separately:

| Outcome | Required evidence |
| --- | --- |
| **Device aligned** | Current device readback matches the qualified source rate, including when no write was necessary. |
| **DAC rate confirmed** | A fresh, stable, locked LED observation from the selected DAC matches the target with calibrated confidence strictly greater than 0.95. |
| **Transition verified** | A track change, an actual device rate update confirmed by readback, a correlated relay click, and a matching LED observation all belong to the same transition. The click can occur before readback but not before the write began. A same-rate track change is aligned, not a verified hardware switch. |
| **Verification incomplete** | One or more required signals are absent, unqualified, or unavailable by the deadline. |
| **Verification failed** | Qualified hardware evidence contradicts the expected rate. Log the mismatch and warn without retargeting or rewriting. |

### Bit-perfect claims

Bit-perfect verification requires an independent digital comparison at the target link against trusted reference PCM for the same rendition. Channel order and sample values must match after accounting for fixed offset and lossless container differences. Rate and lock checks cannot rule out volume scaling, mixing, DSP, or truncation. A passing comparison for a known local asset qualifies only that tested path and asset; it does not establish integrity for an unrelated Apple Music session. Do not display **Bit Perfect** without session-level proof.

## 5. Privacy and clean-room boundaries

Use documented interfaces and explicitly exposed, permissioned observations only. No private notifications, ad hoc undocumented log parsing, proprietary component reverse engineering, or inspection of protected streams. A versioned, bounded parser may use explicitly recognized Music system-log records as unverified correlation evidence when the record is attributed to the current playback lifecycle. Such logs remain non-authoritative, cannot qualify a switching target, and must degrade safely when the log format changes.

Automatic interaction with Music's Lossless panel is disabled by default and requires explicit opt-in, Music monitoring, and Accessibility access. Cancel an in-flight automatic read when monitoring or automatic panel reading is switched off. Do not interact with a panel that was already open or when Music is active. Clear the panel snapshot when Music becomes active; attempt a new read after Music becomes inactive. Report failed or interrupted checks without presenting a depth.

Webcam LED and microphone relay verification are independently opt-in. Request permission only when the corresponding feature is enabled. Analyze signals locally without retaining raw video or audio. Denial or revocation disables the affected verifier, not core monitoring.

## 6. Release acceptance criteria

Timing applies to eligible, unsuperseded transitions on supported configurations. Resource limits are measured on the reference Apple Silicon system.

| Metric | Requirement |
| --- | --- |
| Source format detection | Within 2 seconds of an independently timestamped playback boundary. |
| Rate adjustment | Confirm a required write within 500 ms of starting alignment and within 2 seconds of the playback boundary overall. These budgets are not additive. |
| Menu update | Within 250 ms of accepting a state change. |
| Hardware verification | With verification enabled, return a verified, failed, or incomplete result within 2 seconds of confirmed device readback. |
| Format accuracy | Fewer than 1% of independently labeled supported transitions publish the wrong source format. Count unknowns and misses separately; an unknown on a supported positive case fails the detection gate. |
| Idle | Less than 1% of one CPU core and less than 50 MB resident memory. |
| Normal playback | Less than 3% of one CPU core and less than 80 MB resident memory. |
| Transition handling | Less than 10% of one CPU core on average in the transition window; report brief spikes separately. |

The release report must distinguish supported alignment configurations, monitor-only configurations, and the paths for which digital sample integrity was actually tested.
