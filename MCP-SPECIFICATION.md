# RateCue local agent and MCP adapter: proposed specification

Status: an experimental MCP adapter (read-only by default, control tools by
explicit opt-in), an observation-only pilot, an app control channel with full
CLI coverage, and a local model host are implemented, but live qualification
is not claimed. The existing
[product specification](./SPECIFICATION.md) remains authoritative for RateCue.

## Implemented first-track observation pilot (experimental)

The branch now implements a **narrower offline diagnostic prerequisite**, not
MCP, an agent, a new collector, or an accuracy/latency qualification.
`Sources/DamonPlatform/FirstTrackDiagnostics.swift` defines trace schema 2 and
deterministic diagnostic version 2. Version 1 was replaced before any live
trace was collected, after review showed it could not capture or report the
cases of interest. The existing menu monitor records
only when launched with `RATECUE_FIRST_TRACK_TRACE=1`; absent that exact value,
no trace is created. This flag does not enable monitoring, automatic panel
reading, switching, or any permissions.

### Instrumentation audit and observable contract

| Existing source | Pilot observation | What remains unavailable |
| --- | --- | --- |
| `PlaybackSample.collect` / menu `tick` | Collection-start uptime, main-task availability callback, recorded callback time; playing/paused/stopped/unavailable; reported rate or absent; used, held previous, or discarded sample | Independent playback onset; worker completion time; individual Apple Event timing/error; why an optional property is absent |
| Monitor epoch bookkeeping | Numeric playback/route generations; observed track/process change flags, without saving identities | True listening-session boundary; authenticated track/rendition attribution; device identity |
| Existing log backfill task | Probe start callback and attempt, completion callback; failed/discarded/selected/no-selection; parsed and selector-eligible event counts | Scheduling due time; subprocess completion separate from main-task arrival; raw reader error, log visibility time, rejected raw records |
| Existing lifecycle selector | Whether the unchanged selector chose a decoder report; selected depth and report wall-time offset | Exact rejection reason, independent track identity, unparsed start-only records |
| Existing display update | Computed display depth or absent, attributed to qualified local evidence, panel snapshot, or unverified correlation; recorded when it changes | Pixel presentation time; panel probe outcomes; source-format oracle; hidden-field visibility |
| Existing alignment state machine | Alignment state and target rate, recorded when either changes | Device identity and readback values; write timing; why a write failed |

`atMilliseconds` is the time the main monitor records a callback, on process
uptime relative to the first retained observation, not an independently timed
playback event.
Sample `availableAtMilliseconds` is taken immediately after the monitor awaits
collection; it includes possible main-task scheduling delay.
`collectionStartMilliseconds` comes from the existing sample.
`selectedLogWallOffsetMilliseconds` is a parsed log timestamp minus the
wall-clock time assumed for the first retained observation. Wall-clock jumps and log visibility are
unmeasured; **do not compare it causally with uptime or call it availability**.
No absolute wall time, playback position, IDs, titles, paths, device data,
raw logs, or free-form error/status strings enter the trace. Optional evidence
is omitted in traces; assessment unknowns are explicitly JSON null.

The documented capture boundary is **capture start**: menu-app launch, or the
explicit **Restart First-Track Capture** action, not listening-session start.
“First track” means the first *used* playing sample after that; starting a
capture mid-track is allowed but cannot qualify an actual session-first
track. Monitoring-off, observation failure, or no accepted playing sample does
not prove a playback miss. This pilot deliberately cannot diagnose all causes.

### Bounds, retention, and export consent

Until the first used playing sample, capture keeps only a rolling pre-roll of
at most 64 events and 30 seconds, so idle time cannot exhaust it;
`preRollTruncated` records that older observations were dropped. From that
sample it retains a contiguous prefix, stopping at 512 events or 120 seconds
after the first retained observation, whichever is reached first. Display and
alignment observations are recorded only when they change.
Export is capped at 256 KiB and validated before copying. Recording adds no
queries, tasks, waits, model calls, or disk writes, and never feeds the existing
engine, display decisions, or audio policy. Instrumentation CPU/memory and
contention are still **unmeasured**, not guaranteed zero.

**Advanced Diagnostics → Copy First-Track Trace (Experimental)** is an explicit
clipboard export; collection alone persists nothing. **Delete First-Track
Trace / Stop Capture** immediately drops the buffer and stops capture;
**Restart First-Track Capture** drops it and waits for the next used playing
sample, so a long-running app can be armed before a listening session.
App exit also drops the buffer.

`RateCue first-track-trace restart | stop | export [<file>] | capture <file>`
performs the same explicit actions from the CLI through the
[app control channel](#automation-interface). `capture` restarts, polls once
per second until the capture covers the deadline after the first used playing
sample, then writes the selected file. An app without the launch flag answers
with a fixed "tracing disabled" failure, and a stopped capture answers only
to `restart`. Disable the environment flag for future
launches. Clipboard managers, saved exports, transcripts and model runtimes
have separate retention: deleting the buffer does not delete those copies.
Clear the clipboard and delete any individually selected saved export when
finished. Do not share traces automatically.

### Offline deterministic assessment

`RateCue assess-first-track <trace.json> [--deadline-ms <1...120000>] [--timeline]`
reads only the explicitly selected regular, non-symlink file, with a bounded read.
It rejects unsupported versions, malformed values/timing and cross-kind fields;
unknown extra input fields are discarded, never echoed. The input remains
unauthenticated same-user evidence. Read failures return a fixed error, not a
path or arbitrary decoder message.

The default deadline is 10,000 ms **after the first accepted playing callback**,
not playback onset or a measured product target. Music-reported rate, computed
display depth and device alignment are assessed independently as
`observedByDeadline`, `observedAfterDeadline`, `notObservedByDeadline`, or
`inconclusive`, each with its delay in milliseconds when observed.
`boundaryUncertaintyMilliseconds` is the unobserved interval before the first
used playing sample: playback may have begun anywhere within it, so idle
polling alone can hide up to about a second. The rate outcome means Music
reported a rate, not that RateCue switched; `deviceAligned` reports the
alignment state machine reaching `aligned`, which never happens when automatic
switching is off or the configuration is monitor-only.
An interruption, unheld unavailable sample, process change or next observed
track bounds the first-track window; an incomplete capture is not labeled a
miss. A negative needs an observed sample or display callback covering the
deadline, not just elapsed time at export. Because a capped capture is a
contiguous prefix, it can still establish such a negative.
Held/discarded samples cannot establish a rate; stale-generation displays
cannot establish depth. Route/rate generations are retained, not merged away.

Allowlisted findings cite zero-based trace event indices. They describe failed
reads, empty parsed results, selector eligibility/withholding, retention,
discard, playing samples without a reported rate, failed alignment, generation
changes, collection-to-callback windows over one second and observation gaps
over two seconds; none is a root-cause assertion. Routine idle polling waits
up to one second and is not a gap. Findings use only events recorded by the
deadline, from the first used playing sample onward, plus playing samples
that were observed but not used before it. Late detection outcomes are
explicitly retrospective and may use later observations.
`rootCause`, `independentPlaybackBoundary`, and `logVisibilityTime` are always
null in diagnostic version 2.

`--timeline` adds a compact rendering of the whole capture: one row per event,
with runs of identical samples collapsed, times relative to the first used
playing sample, and unchanged displays omitted. Rows contain only enumerated
words and integers from validated fields, and are capped at 120. A selected
probe row also shows `recordLogged`, the chosen log record's own timestamp on
the same axis. It comes from a wall clock, so it is approximate against the
other times and says when the record was written, not when it became readable.

`ruleHypothesis` is one label from a closed list, chosen by the first
condition that holds over the first-track window. It is retrospective and is
a hypothesis consistent with the trace, never a proven cause:

1. `insufficientTrace`: no used playing sample, or the depth outcome is inconclusive.
2. `deviceAlignmentFailed`: the alignment state reached `failed`.
3. `noDelay`: a depth was displayed by the deadline.
4. `observationStalled`: a sample took over one second to collect, or followed
   a gap of over two seconds.
5. `musicRateReportedLate`: Music's rate was not reported by the deadline.
6. `logQueryFailed`: a log query failed.
7. `logEvidenceLate`: a depth was displayed after the deadline.
8. `logEvidenceAmbiguous`: a query found eligible records but none was selected.
9. `noMatchingLogEvidence`: none of the above.

The first live capture corrected rule 5: Music commonly omits the rate for the
first second or two, which the original rule mistook for the cause of a
13.8-second delay. One label cannot apportion a delay; read the timeline for
that. A failed probe can coexist with delayed depth,
but this does not establish that it caused the delay.

The optional local host can explicitly read a user-selected export through
`--trace`, using the fixed bundled CLI for validation, assessment and timeline.
It sends the assessment and timeline to the local model, never the file, its
path, or anything outside those typed fields. It reports two labels from a
closed list of mechanisms, in a fixed decision order:

- `ruleHypothesis`: the documented decision list, applied by the CLI to the
  typed events and withheld from the model.
- `agentHypothesis`: the model's choice, with the rows it says it found. Each
  row is checked against the timeline; `misread` lists the ones it got wrong.

Both are hypotheses consistent with the trace, not proven causes, and both see
retrospective outcomes. The host refuses evidence that would not fit the model
context and treats a cut-off answer as an error. In synthetic evaluation no
tested local model read traces reliably, while a frontier model given the
same cases read all of them correctly; see the
[plan](MCP-PLAN.md#synthetic-trace-reading-evaluation).

The model need not run on the music appliance. `--server` on the host and
evaluation scripts selects a model server on another machine the user
controls, and `--api openai` selects the OpenAI-compatible API in place of
Ollama's. This is an explicit per-invocation choice with no default and no
stored setting. RateCue, the MCP helper and the trace stay on the appliance;
the same typed assessment and timeline, or redacted snapshot, that a local
model would receive are sent to that server, and nothing else. The remote
server, its network and its logs are a separate trust boundary that the user
must secure; these servers typically have no authentication.

Frontier models are the reference for validating local-model results. RateCue
ships no network client or credentials for this. `evaluate-agent.py
--export-cases` writes the unlabeled synthetic cases with their instructions,
and `--score-answers` scores any model's answers with the same row checks.
`local-agent.py --trace … --export-prompt` and `--check-answer` do the same
for one real trace. That prompt holds only the typed assessment and timeline,
and sending it to any service is an explicit user action, never automatic. This offline path does
not use MCP or change playback, and is not suitable for blinded
format-estimation evaluation.

This is deterministic **diagnostic replay**, not reconstruction of the
correlation engine, independent ground truth, or a ready blinded agent dataset.
The pilot itself creates no MCP transport. The remaining research,
privacy, source availability, labeling and resource gates below still apply.

## Long-term objective and staged scope

The long-term goal is to evaluate whether a local LLM/agent can estimate the
playing rendition's sample rate and bit depth from the preponderance of
available, attributed evidence, and improve on RateCue's current correlation
engine. This is a research objective, not a claim that an LLM is accurate or
that combined evidence establishes the actual rendition. Related observations
may share a source and must not automatically count as independent votes.

First, test whether an agent can usefully explain a concrete issue: the first
track in a listening session can be missed or severely delayed. A supported
explanation must cite observed events and distinguish facts from hypotheses;
when timing or evidence cannot establish the cause, it must say so. Compare
its explanations against a simple deterministic diagnostic, not just against
no explanation. This evaluates diagnostic usefulness, **not format accuracy**.

Next, evaluate rate and depth predictions in blinded offline replay using
independently labeled cases and only evidence available by each decision
deadline. Compare them with the current engine on the same cases; report
wrong predictions, abstentions, misses, late answers and coverage separately.
An offline result can motivate a later shadow-mode trial, but does not prove
live accuracy or authorize switching.

Only after useful, accurate and practical results should a separate decision
consider an opt-in agent estimate in the display. Any future effect on switching
requires a separate specification and qualification; the existing deterministic
write and route safeguards remain authoritative. No estimate can establish
bit-perfect playback. The initial prototype below neither changes the display
nor influences switching.

## Initial purpose and boundaries

Allow a user to ask a local AI assistant to explain RateCue's current diagnostics
without giving the assistant control of playback or audio hardware. The target
reference machine is an Apple Silicon M2 Mac mini with 8 GB unified memory.
The adapter is optional and disabled by default; RateCue works unchanged
when no assistant, model, or adapter is running.

MCP is a tool protocol, not a model or evidence source. A separate local host
runs a model, connects as MCP client, and launches the adapter. The deterministic
RateCue monitor and policy remain the sole authorities for its existing display
and decisions. In this initial phase the assistant's interpretation is never
fed back into the correlation engine, confidence resolution, display, or audio
write path.

```text
Music and audio hardware -> RateCue monitor -> validated menu snapshot
                                                |
User <-> local assistant host <-> MCP stdio adapter
```

An assistant may summarize current evidence, explain a withheld estimate, and
identify missing information. It must not infer the true source format from
an output-device rate, treat model scores as calibrated probabilities, claim
bit-perfect playback, or report a stale snapshot as current. A local LLM cannot
repair the known post-skip anchor or prove that log events identify the track.

The current snapshot does not contain a complete event-by-event trace and is
not enough to explain every delay or independently estimate the source format.
For research, the pilot above supplies only an initial trace subset. Richer
opt-in, bounded and redacted collection must be designed and tested before use.
It should distinguish playback boundary, sample
observation, Music-reported rate, log event time, collector arrival and probe
outcome, attribution decision, publication and errors when actually available.
Preserve provenance, playback/route generation, clock basis and uncertainty;
mark absent timestamps and unknown attribution explicitly. A log timestamp is
not proof of when a record became readable. Do not collect raw logs, titles,
paths or device identifiers by default, or invent missing data.

Offline replay of such traces is independent of the MCP adapter: no MCP server
or live model is required to evaluate diagnostic usefulness. The adapter now
offers the typed assessment and timeline of the current capture, never the
raw trace; retaining traces or adding new live collection still requires its
own privacy, safety, and resource review.

## Automation interface

Project rule: every RateCue function, shipped or experimental, has a CLI or
API entry point, so the MCP adapter and test harnesses can drive it without
the menu or the clipboard.

**App control channel.** Functions that need the running menu app's state or
privileges go through one request/response exchange
(`Sources/DamonPlatform/AppExchange.swift`). A client posts a local
distributed notification carrying an allowlisted action, an optional
allowlisted argument and a random request UUID. The app performs the same code
path as the matching menu item, without its alerts, and writes one owner-only
JSON response file in its Application Support directory. The client reads it
through a bounded reader and deletes it; on later requests the app removes
unconsumed response files older than 60 seconds. Failures are fixed codes,
never free-form text. Any same-user
process can post a request and read that directory. Such a process can
already run the CLI, so this adds convenience rather than privilege, and it is
not an access control.

| Function | CLI | MCP tool |
| --- | --- | --- |
| Current diagnostics and correlation detail | `menu-status`, `app diagnostics` | `ratecue_get_diagnostics` |
| Fresh Music and device observation | `status`, `devices` | CLI only: device identifiers |
| Qualification snapshot | `app qualification-snapshot` | `ratecue_get_qualification_snapshot` (typed subset) |
| Preferences: read | `config show` | `ratecue_get_settings` (on/off values only) |
| Monitor Music, Auto Switch, Show Rate, Show Depth | `config set` | `ratecue_set_preference` (opt-in) |
| Preferred device, authorized local audio | `config set --device`, `--local-audio` | CLI only: identifiers and paths |
| Automatic panel reading, camera and relay verification | `config set --auto-read-panel`, `--camera-verification`, `--relay-verification` | CLI only: they operate Music's interface or capture hardware |
| Music panel and log evidence | `probe-format`, `log-format` | CLI only |
| Playback transport | `playback` | `ratecue_playback` (opt-in; routed through the app) |
| First-track capture: restart, stop | `first-track-trace restart`, `stop` | `ratecue_restart_first_track_capture`, `ratecue_stop_first_track_capture` (opt-in) |
| First-track capture: export, wait | `first-track-trace export`, `capture` | CLI only: raw trace |
| First-track assessment, rule hypothesis, timeline | `assess-first-track --timeline` | `ratecue_get_first_track_assessment` |
| Session log | `app logs` | CLI only: free-form text |
| Launch at Login, Quit | `app login-item`, `app quit` | CLI only |
| About, Credits, Help | `--version`, `--credits`, `--help` | CLI only |
| Accessibility and Automation access | `app diagnostics` reports Accessibility; `authorize-music` requests Automation | Granting stays with the user |
| Source and route check, fixtures, guarded rate-write trial | `check`, `test-fixture`, `test-switch` | CLI only: hardware writes are never offered to a model |
| MCP helper itself | `Scripts/mcp-call.py [--control] list \| <tool> [json]` | — |
| Local model host and evaluation | `Scripts/local-agent.py`, `Scripts/evaluate-agent.py` | — |

**MCP tools.** By default the helper offers four read-only tools. Control
tools appear only when the host launches the helper with
`RATECUE_MCP_ALLOW_CONTROL=1`; that setting is the user's consent, per helper
process. Every tool returns typed values only: no device names, paths, titles
or free-form status text. No tool writes audio hardware. Turning `autoSwitch`
on only lets RateCue's own qualified deterministic engine switch rates, with
its existing safeguards. The helper holds no Automation permission of its
own: transport commands are carried out by the menu app. Given the measured
unreliability of local models, enabling control for a model-driven host is at
the user's risk; test scripts are the intended first user.

## First-release scope

- The original on-demand tool, `ratecue_get_diagnostics`, with an empty input object
  (`additionalProperties: false`), returns a bounded, structured, redacted
  current menu diagnostic snapshot. No automatic polling or background model.
- Source data is the running menu app's existing `menu-status` snapshot. Reuse
  its schema-version, five-second age, and current-process validation; do not
  silently read an old file when validation fails. A response is a point-in-time
  observation, not a guarantee that playback has not since changed.
- Preserve `snapshotAt`, playback state, publication status,
  correlated depth or null, conflict/evidence flags, rate and depth detection
  timings or null, model version, provisional priors and posteriors, and
  bounded contribution provenance. Explicitly label the model scores
  **uncalibrated** and the correlated estimate **unverified**. Preserve unknown
  as null; never substitute `mostLikelyDepth` as an accepted estimate.
- Include a response schema version and clearly distinguish the adapter schema
  from the underlying snapshot and correlation-model versions. Optional or
  absent data must not be presented as a zero, success, or fresh reading.
  Unsupported source versions, missing app, stale data, and read failures
  return explicit MCP tool errors, not success-shaped defaults.
- Do not return process IDs, raw logs, track identifiers, file paths, device
  identifiers, arbitrary error text, or panel/log status strings by default:
  arbitrary strings can contain sensitive data or instructions. Map needed
  status information to a bounded allowlisted representation or omit it.
  Diagnostics and tool results are data, never instructions to the model.
- Do not expose `status`, device enumeration, live log probing, panel reading,
  fixture playback, command execution, or hardware writes. Transport, four
  on/off preferences and capture restart/stop are offered only with the
  explicit opt-in described under [Automation interface](#automation-interface).
  The existing snapshot has no transition history or benchmark
  dataset; the adapter must say these are unavailable rather than invent them.

### Snapshot contract and trust

The existing schema-v2 file in Application Support is a snapshot, not an
authenticated live connection. The `menu-status` CLI currently checks schema
version, a nonnegative age of at most five seconds, and whether the recorded
PID belongs to a running RateCue process. It does not authenticate the writer,
validate all values, or guarantee that a PID has not been reused. These checks
reduce accidental staleness; they do not prove integrity against a same-user
process. Treat the result as untrusted diagnostic evidence.

The prototype uses a separate adapter executable and shares the current-process
and freshness validation with the existing CLI. The CLI retains its existing
file reader and error behavior; the adapter uses its own bounded safe reader.
The adapter uses the standard snapshot location and ignores the
`RATECUE_DIAGNOSTICS_DIR` override; the current CLI's override behavior remains
unchanged. Check file ownership, reject symlinks, and bound the read before
decoding. These checks do not protect against a malicious process running as
the same user. Do not claim authenticated provenance unless a separately
designed and tested authenticated channel is added.

The v1 response is an explicit allowlist, not a copy of source JSON:

| Output | Source and constraints |
| --- | --- |
| Adapter schema, source schema and model version | Fixed adapter version; source schema 2; model 2 for a real correlation context. `noContext` has null model and scores, even though the source supplies defaults. Reject unsupported context versions. |
| `snapshotAt`, playback state | Valid timestamp; state `playing`, `paused`, `stopped`, or null. |
| Publication status and correlated depth | Allowlisted `noContext`, `published`, `withheldForConflict`, `priorOnly`, `belowNinetyPercentThreshold`; depth 16, 24 or null, consistent with publication status. |
| Evidence and conflict | Boolean flags; require consistency with publication status and candidate. |
| Priors and posteriors | Percentages 0–100 in complementary pairs, unrounded probability finite and 0–1; null when no context. Mark these values uncalibrated. |
| Contributions and provenance | Only recognized source and strength enum values, candidate 16/24/null, finite numeric values, with a bounded item count. Reject unknown or malformed values rather than forwarding arbitrary text. |
| Rate/depth detection timing | Nonnegative integer milliseconds or null; observation-relative, not independently timed. |

Omit `menuTitle`, `certainty`, `mostLikelyDepth`, process ID, arbitrary status
strings and any fields not listed above. Displayed-title formatting is not a
safe data contract and the snapshot does not separately expose all displayed
rate/depth fields. Do not derive missing source format from it. The tool declares its exact JSON keys and constraints in an output schema and
validates source values and cross-field consistency before constructing output.
No-context default
50/50 values are not evidence and must not be presented as a real posterior.

Example user question: “Why is the bit depth unknown?” A useful answer reports
the current evidence and publication status, acknowledges uncertainty, and
does not turn a prior or unverified correlation into a factual source depth.
The adapter returns structured facts; prose generation belongs to the host.
Because a model can hallucinate, reliable answers are an evaluated goal, not
an enforceable property of the adapter.

## Protocol and lifecycle

- Use the standard MCP **stdio** transport: a user-configured local host launches
  the adapter as a subprocess, sends newline-delimited JSON-RPC on stdin, and
  reads protocol messages only from stdout. Diagnostics go to stderr, with
  sensitive details omitted. Implement initialization/version negotiation,
  the initialized notification, tool discovery, schema validation, cancellation,
  and shutdown using a
  maintained compatible SDK where practical; verify the selected host's
  protocol compatibility before pinning versions.
- The adapter must not listen on a network port, access the internet, start the
  model, download assets, request macOS permissions, or start/stop RateCue.
  Data that leaves the adapter is visible to the client: the **host**, model
  runtime, conversation storage, other tools, and their network settings are
  separate trust boundaries. Locality requires the user to select and verify
  an offline-capable host and runtime; stdio alone does not ensure privacy.
- Launch only when explicitly configured by the user. On stdin closure or host
  exit, terminate promptly and leave RateCue running. Cancelled requests stop
  their own work without terminating RateCue or unrelated requests.
  No persistent adapter cache or transcript is required. Invalid responses,
  subprocess failures, and oversized inputs/outputs must be reported and
  bounded; no shell invocation or user-controlled executable path.
- Read-only tool annotations are descriptive, not an authorization boundary.
  Trust and permission decisions remain with the user and host. Never expose
  a general-purpose CLI wrapper. Treat data from the snapshot as untrusted.
- Declare a tool output schema; return structured content with a compatible
  serialized-text fallback. Malformed JSON-RPC, unsupported methods and invalid
  protocol requests use protocol errors; source failures use tool results with
  `isError: true` and allowlisted, actionable messages. Follow the negotiated
  MCP version's lifecycle and cancellation semantics rather than inventing
  responses to notifications.
- Initial implementation limits: one in-flight call, at most four calls per
  second, 64 KiB per input line, 64 KiB per snapshot file, 32 KiB per response,
  and a two-second source-read deadline. Reject or cancel excess work explicitly;
  never return truncated JSON as success. These are engineering limits to
  validate with the SDK and selected host, not evidence of performance.
- Prototype the executable as a separately launched helper inside the signed
  app bundle. Packaging must sign and verify it, and the host's configured
  path must be documented. Upgrades, rebuilds, app removal, a missing helper,
  and host disconnection must fail visibly; the adapter must not acquire
  extra Automation, Accessibility, or audio permissions.

### Implemented prototype details

`RateCueMCP` is a dependency-free, narrowly scoped stdio implementation rather
than an MCP SDK. It supports `2025-11-25` and `2025-06-18`; an unsupported
requested version receives `2025-11-25` for the client to accept or reject.
It emits protocol messages only on stdout and exits on stdin EOF. There is no
MCP shutdown request; the client closes the transport. A cancelled call stops
and, as MCP recommends, receives no response. Each source read has a two-second
response deadline. A stalled kernel file operation cannot be forcibly stopped:
the one worker slot remains occupied until it returns, while EOF still exits.
The experimental `Scripts/local-agent.py` host has been exercised against this
adapter and a locally installed Ollama model. This narrow smoke test does not
establish general host compatibility, offline guarantees, diagnostic accuracy
or performance qualification.

The success object has `adapterSchemaVersion` (1), `sourceSchemaVersion` (2),
`correlationModelVersion` (2 or null), `snapshotAt`, `playbackState`,
`publicationStatus`, `correlatedDepth`, `estimateQualification` (unverified),
`scoreQualification` (uncalibrated), `evidenceAvailable`,
`correlationConflict`, `usedHighRatePrior`, `prior16`, `prior24`, `posterior16`,
`posterior24`, `unroundedProbability24`, `contributions`, `provenance`,
`rateDetectionMilliseconds`, `depthDetectionMilliseconds`, `transitionHistory`
and `benchmarkData`. The last two are always null; model values are null for
`noContext` and its contribution list is empty. The advertised output schema
gives types, ranges and enum values; results also contain matching JSON text
for clients without structured-content support. Timings are observation-relative,
not independent playback timestamps. The helper checks the final directory and
file for symlinks, owner and regular-file type, but cannot authenticate a
same-user writer or eliminate PID reuse.

## M2 / 8 GB operating constraints

The reference machine is a dedicated Apple Music streaming appliance that also
hosts RateCue development; it is not a general productivity machine, so
budgets need not reserve headroom for unrelated desktop applications.
It is still a shared-memory machine: macOS, Music, RateCue, the model runtime,
model weights, context/KV cache, and the assistant host compete for the same
8 GB. A model's download size is not its peak memory footprint. Start by
testing an already installed, small quantized model with a modest context and
one concurrent request; the actual model, runtime, quantization and context
size are **to be selected by measurement**, not assumed to fit. Neither a
model nor a runtime is bundled or installed by this specification.

Candidate engineering budgets, to be measured before adoption:

| Metric | Proposed target, not a measured result |
| --- | --- |
| Adapter idle | No polling; under 1% of one CPU core averaged over 5 min, under 50 MB resident memory |
| Diagnostic request | p95 under 250 ms adapter-only for 100 warm local requests; errors and cold starts reported separately |
| Memory and playback | No yellow/red pressure lasting 10 consecutive seconds or longer and no increase in swap used between start and end of any 15-minute run; no audible interruptions reported |
| Existing RateCue | Existing product CPU, memory, timing and audio safety requirements still apply; measure paired assistant-off and assistant-on runs |

These are proposal gates, not guarantees. Record baseline and delta per process,
plus system-wide memory pressure, swap, and peak physical footprint because
unified memory and shared pages make summing RSS misleading. If a candidate
fails, reduce context/model size or keep the feature experimental; never
degrade RateCue's monitoring or auto-switch safeguards to make it fit.
Model load time and answer latency are measured separately from adapter latency.
No inference speed or playback-latency guarantee is assumed.
Sample system pressure and swap at one-second intervals, recording the tool
and units. If pressure state or swap cannot be measured, the gate is
unverified. These conservative proposed thresholds may be revised only with
documented evidence, not by ignoring failed runs.
Measure first-track detection, misses and switching delays with the assistant
off and on. Off-path execution must not wait on inference; still measure
resource contention because a separate process cannot guarantee zero impact.
Consider better hardware only if a useful, independently evaluated model
fails measured M2 resource or latency gates; faster hardware does not repair
missing evidence or untrustworthy inferences.

## Acceptance

1. A compatible local host discovers only the read-only tools unless the user
   has opted in to control, and can request a valid snapshot. No hardware
   write, identifier or free-form text is reachable through MCP.
2. Tests verify snapshot validity, null/unknown handling, schema and version
   rejection, bounded input/output, explicit failures, disconnect cleanup,
   redaction, and absence of unintended playback/configuration/device changes.
3. Representative prompts and adversarial diagnostic strings are evaluated
   for uncertainty, privacy and instruction following; measure and report
   unsupported claims, not just successful tool calls. A failure cannot alter
   audio or affect deterministic policy.
4. On the reference machine, publish reproducible assistant-off/on
   measurements and model/runtime configuration. Failure to meet proposed
   budgets or lack of an appropriate local host blocks a qualified release,
   not normal RateCue operation.

## References

- [MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
  and [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
- [Development and test plan](./MCP-PLAN.md).
