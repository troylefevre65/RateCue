# RateCue local agent and MCP adapter: development and test plan

This plan accompanies the [local MCP specification](./MCP-SPECIFICATION.md).
The read-only snapshot prototype, a first-track trace and a local Ollama host
exist. A synthetic evaluation found that no tested local model reads a trace
reliably; privacy and live resource measurements remain unqualified.

## Implemented prerequisite and next gates

The experimental observation-only subset of pilot A is implemented; see the
[trace contract and instrumentation audit](MCP-SPECIFICATION.md#implemented-first-track-observation-pilot-experimental).
It does not complete A's independent session labeling, human scoring, or agent
comparison. The separate snapshot MCP adapter is not part of the pilot.

- Menu monitor: `Sources/Damon/main.swift`; exact environment opt-in, bounded
  memory-only callbacks from existing collection, epoch, log, display and
  alignment paths; explicit clipboard export, restart and delete/stop actions.
- Schema/recorder/offline diagnostic: `Sources/DamonPlatform/FirstTrackDiagnostics.swift`.
- Offline command: `Sources/DamonPlatform/DamonCLI.swift`,
  `assess-first-track <trace.json> [--deadline-ms <N>] [--timeline]`, which also
  reports the rule hypothesis, and `first-track-trace restart | stop | export |
  capture` for a running trace-enabled app.
- Automation: every menu function has a CLI entry point through the app
  control channel (`Sources/DamonPlatform/AppExchange.swift`); the MCP helper
  offers four read-only tools and four opt-in control tools
  (`Sources/RateCueMCPCore/Tools.swift`); `Scripts/mcp-call.py` calls it
  without a model. See the
  [coverage table](MCP-SPECIFICATION.md#automation-interface).
- Synthetic tests: `Tests/DamonTests/FirstTrackDiagnosticsTests.swift`;
  late/missing/short/capped capture, long idle before playback, alignment and
  delays, timeline rendering, interruption/next track, stale generation,
  held/discarded samples, eligibility/failures, timing gaps, bounds, malformed
  data, redaction and null unknowns. Existing transition/log tests remain
  authoritative, including the known post-skip position-anchor issue.

The trace-enabled pilot has since run live: CLI restart, stop and export
returned real stopped-state samples, display and alignment observations; a
`capture` with nothing queued in Music timed out cleanly without writing a
file; every `app` command and all eight MCP tools answered against the
running app. One playing first track has since been captured; see
[First live capture](#first-live-capture).
No live first-track trace was collected, playback changed or permission
requested during the original pilot implementation. A later tool-call smoke test used the
already running menu app; no first-track diagnosis was evaluated.
Release compilation and synthetic replay tests do not qualify live overhead.
The code does not modify existing playback, switching or panel-read decisions.

Before an actual trial:

1. Obtain consent for launching a trace-enabled build and for any export.
   Establish an independently documented listening-session boundary; label
   mid-track launches unqualified for actual session-first-track conclusions.
2. Use existing playback without transport/fixture actions unless separately
   authorized. Record assistant/trace-off baselines and trace-on CPU/memory,
   detection and switching behavior; test deletion and export retention.
3. Audit whether this narrower trace can answer the selected diagnostic
   question. Missing worker timing, log visibility, individual probe errors,
   anchor input and detailed rejection/panel outcomes remain unknown; add
   collection only with a separately reviewed evidence/privacy design.
4. Predeclare cases, deadline, rubric and success criteria; freeze diagnostic
   version 2. Human-review event citations and distinguish observed delay from
   actual playback-onset latency. Prepare deadline-limited agent inputs that
   exclude later observations; the CLI's late outcomes are retrospective.
5. Verify the selected host/model's privacy before any comparison. Missing
   independently labeled cases, human review, resource measurements or model
   comparison leave the pilot **inconclusive**.

### Local host smoke test

The development machine has Ollama and `qwen2.5:1.5b` Q4_K_M installed.
The optional `Scripts/local-agent.py` host connects to the Ollama loopback
API and starts the bundled MCP helper. One live snapshot tool-call round trip
completed, but the model's answer contained a contradictory statement about
the schema. One less explicit prompt also failed to invoke the tool. These
are feasibility observations, not accuracy or privacy qualification; no
first-track evidence was supplied. The model may require a different prompt
or a better model, and must not control RateCue.

With the current host, that snapshot round trip completed with two of the five
installed models (`qwen2.5:1.5b`, `granite4:3b`). The other three failed
safely at the tool step: one sent unsupported arguments, one made no call and
one ran out of output. Adding one sentence to the system prompt was enough to
stop `qwen2.5:1.5b` calling the tool, so these models are prompt-fragile.

### Review of the first offline trial

The first offline path sent the model only the deterministic summary: fact
names and event indices, no times, and a root cause that is always null. Its
prompt also forbade naming causes, so the best possible answer was a
paraphrase, and both `qwen2.5:1.5b` and `qwen3:1.7b` got even that wrong on a
few hand-made cases. A review then found defects that would have undermined a
live trial, all now corrected:

- A realistic capture with 90 seconds of idle time produced a 2,102-token
  prompt against a 2,048-token context. Ollama evaluated 1,026 tokens, the
  models answered without the system rules, and the host printed the cut-off
  result as normal. The host now refuses oversized evidence, asks the server
  not to truncate, and treats a cut-off answer as an error.
- The overflow came from an observation-gap finding whose one-second threshold
  equalled the idle polling interval, so it fired on every idle poll.
- Capture was anchored to app launch, so idle time consumed it and playback
  started after two minutes was not captured at all.
- Any capped trace was reported as inconclusive, including a depth that
  demonstrably never appeared before the deadline.
- The trace did not record device alignment.

### Synthetic trace-reading evaluation

`Scripts/evaluate-agent.py` tests the necessary condition for everything that
follows: can a local model read a trace and apply a short, explicit decision
list? It generates seeded schema-2 traces with realistic polling, probe retry
and backoff timing, each with one injected mechanism (ten generator categories
mapping to nine labels), runs them through the bundled CLI, and gives the model
the assessment and timeline. The model must locate seven specific rows, copy
one outcome, and choose the first mechanism whose condition holds. The host
checks every row the model names against the timeline.

The same decision list applied mechanically (`ruleHypothesis`) matches the
generator's label on 60 of 60 development and 60 of 60 held-out traces. That
is by construction: the rule and the generator share definitions. It shows the
task is well-posed, not that the rule is right about real playback.

Development set, 20 traces (correct labels):

| Model | Free-form answer | Scaffolded rows | Scaffolded + thinking |
| --- | --- | --- | --- |
| `qwen2.5:1.5b` | 4 (4 answers cut off) | 2 | — |
| `qwen3:1.7b` | 3 | 3 | 2 |
| `granite4:3b` | — | 6 | — |
| `phi4-mini` | 6 | 7 | — |
| `qwen3:4b` | 4 | 6 | 0: no answer within 2,560 output tokens; median 99 s, up to 129 s per trace |

Held-out set, 30 traces, scaffolded prompt frozen beforehand, run once:

| Model | Correct | 95% interval | Every row read correctly | Median seconds | Loaded size |
| --- | --- | --- | --- | --- | --- |
| Mechanical rule | 30 / 30 | — | — | under 0.1 | — |
| Frontier model (reference) | 30 / 30 (100%) | 89–100% | 30 / 30 | not timed | not local |
| `qwen3:4b` | 11 / 30 (37%) | 22–54% | 3 / 30 | 7.8 | 3.2 GB |
| `phi4-mini` | 9 / 30 (30%) | 17–48% | 4 / 30 | 6.8 | 3.1 GB |
| `granite4:3b` | 9 / 30 (30%) | 17–48% | 4 / 30 | 5.5 | 2.5 GB |
| `qwen3:1.7b` | 5 / 30 (17%) | 7–34% | 8 / 30 | 3.7 | 1.5 GB |
| `qwen2.5:1.5b` | 4 / 30 (13%) | 5–30% | 3 / 30 | 2.6 | 1.2 GB |

Always answering the most common label would score 6 of 30 (20%). Intervals
are Wilson intervals treating traces as independent draws from the generator.

The frontier row is a fairness check on the test itself. The harness exported
the same 30 unlabeled cases and the same instructions; one frontier model,
run as a separate agent session told to answer by reading alone, wrote its
answers to a file, and the harness scored them with the same row checks. It
labeled every case correctly and named a correct row for every field. So the
instructions and timelines are sufficient, and the local results reflect
model capability, not an unfair test. Caveats: one run of one model, and its
use of no code is self-reported.

Resource observations during these runs, with no music playing and therefore
no playback impact measured: swap in use rose from about 2.6 GB to 4.2 GB
while `phi4-mini` ran, and to 10.8 GB with 9% memory free while `qwen3:4b`
ran with thinking at an 8K context. It fell back to about 1.9 GB once that
model was unloaded.

Limits: the traces are synthetic and single-cause; one author wrote the
generator, the rule and the prompt; the held-out set comes from the same
generator and only guards against tuning to individual traces; the
development row-reading counts were affected by a since-fixed checking error
and are not reported; and 30 traces give wide intervals. None of that rescues
the result: the best model's upper bound is 54% on a task a nine-line rule
does perfectly.

**Decision.** The diagnostic-usefulness gate fails for every tested local
model of 4B parameters or fewer on this machine, with free-form answers,
scaffolding and thinking alike, on a test a frontier model passes completely.
Frontier models are therefore the reference for validation and accuracy
checks: use `--export-cases` and `--score-answers` for the synthetic set, and
`--export-prompt` and `--check-answer` for a real trace. Until a local model
passes this same harness:

- Do not treat `agentHypothesis` as evidence about a real trace. Use the
  deterministic assessment and `ruleHypothesis`; the model's output is shown
  only with its row checks beside it.
- Do not start the blinded format-estimation evaluation (stage B). A model
  that cannot read a 25-row timeline cannot weigh evidence for rate and depth.
- A live first-track capture is still worth collecting: it tests the trace
  and the rule against a real delay, independent of any model.
- The host and evaluation scripts can now use a model server on another
  machine (`--server`, `--api openai`), so larger models can be tested on
  existing hardware with no load on the music appliance. The path was
  verified against this Mac's own Ollama through its OpenAI-compatible
  endpoint: identical scores to the native API on the same ten cases. The
  first remote result is below.
- Larger models were not tested on the M2. 8B-class models at this quantization are
  about 5 GB on disk and larger once loaded, which does not fit beside Music
  on 8 GB given the swap seen at 3 GB. Trying one means more memory, and it
  must pass this harness before anything else is built on it.

### Remote 27B model on the LAN

The same frozen held-out set was run once against
`orcarouter-bonsai-27b-uncensored` (27B, 1.75-bit ternary GGUF, 5.9 GB,
64K context) served by llama.cpp on a Windows desktop with a 16 GB GPU,
reached over the LAN with `--server http://<host>:8080 --api openai`. Nothing
ran on the music appliance except the harness.

| Mode | Correct | 95% interval | Invalid | Every row read correctly | Median seconds |
| --- | --- | --- | --- | --- | --- |
| No thinking, 600 output tokens | 18 / 30 (60%) | 42–75% | 0 | 29 / 30 | 17.3 |
| Thinking, 6,000 output tokens, 10 cases | 5 / 10 | 24–76% | 5 (300 s timeout) | 5 / 5 | 292 |

It is a reasoning model: with thinking left on, a first run at 600 tokens
produced no answers at all (10 of 10 cut off mid-reasoning at about 11.6
tokens per second). The OpenAI-compatible path now sends
`chat_template_kwargs.enable_thinking` from the existing `+think` suffix, so
`model` runs without thinking and `model+think` with it.

Without thinking it reads the timeline almost perfectly but applies the
decision list poorly: all 12 errors pick a later or easier label
(`logEvidenceLate` 9 times, `noDelay` for all three alignment failures)
instead of the first rule whose condition holds. With thinking, every answer
that finished was correct, but only five cases finished within the
300-second request limit, so 5 of 5 is a biased sample, not evidence of a
pass. At about five minutes per trace it would also be too slow to be
practical.

**Decision.** This is the best non-frontier result so far (60% against 37%
for the best local model, and near-perfect row reading), but it still fails
the gate on a task a nine-line rule does perfectly. It read more rows
correctly than the smaller models, but the differences in size and
quantization were not isolated. Before buying
hardware, the next tests are a conventionally quantized 14B–32B instruct
model (4-bit, about 9–19 GB) on the same server, and thinking runs with a
longer request limit on a subset, to tell whether this result is limited by
size, by the 1.75-bit quantization, or by the absence of reasoning.

### First live capture

One real first track has been captured with the automated path: capture armed
by CLI, playback started by the user from a stopped Music with nothing queued,
trace exported by CLI. The device was already at the track's 44.1 kHz.
The depth (16-bit, by unverified log correlation) was displayed 13,764 ms
after the first used playing sample:

| Segment | Milliseconds | What the trace shows |
| --- | --- | --- |
| Music reports no rate | 0 – 1,410 | Three used playing samples without a rate; log queries cannot start |
| Five unsuccessful queries | 1,410 – 9,721 | Each returned 8 format records, none eligible; 5,371 ms in flight, 2,940 ms waiting |
| Retry wait | 9,721 – 12,827 | The schedule's 3-second gap |
| Sixth query | 12,827 – 13,762 | 9 records, 1 eligible, selected |
| Display | 13,762 – 13,764 | |

The selected record's own log timestamp is about +9,500 ms. If that is
roughly right, the record did not exist for the first four queries, was
written about 0.2 s before the fifth returned, and then waited about 4.3 s
to be picked up. So this delay was mostly Music not yet having logged the
record, plus one retry gap; it was not a failed query, a stalled observer or
an alignment problem. Playback may also have begun up to about 1 s before the
first used sample: the previous observation was 1,160 ms earlier.

Not established: why the record is logged about 9.5 s in; whether the fifth
query could have seen it; whether this timing is typical or particular to
this track or session. The timestamp comes from a wall clock and is
approximate against the other times. One capture supports no general claim
and no change to the retry schedule yet.

Validation. The original rule labeled this capture `musicRateReportedLate`
because a rate was missing for the first 1.4 s; that was a poor summary and
the rule was refined (see the specification). The refined rule labels it
`logEvidenceLate` and still matches all 120 synthetic traces. A frontier
model was then given the 30 held-out cases under the refined instructions
plus this capture as an unlabeled 31st case. It again scored 30 of 30 with
every row correct, labeled the capture `logEvidenceLate` with no misread
rows, and its independent open-ended reading produced the same segments and
figures as the table above. Local models were not re-run under the refined
wording, and none was run on this capture: loading one during playback was
avoided.

Next: collect more first-track captures, now one command each, before
drawing conclusions about the log record's timing or tuning the retries.

### Monitored listening session

A script saved each full capture and re-armed it while the user skipped,
restarted and paused tracks for six minutes. The three saved captures hold 33
detection cycles (24 track changes, 8 restarts, 1 resume); Music's own
unified log for the same window supplied reference decoder records, not
independent source-format ground truth. Rates were 44.1,
96 and 192 kHz. The alignment state stayed `unknown` throughout, so this
session says nothing about switching.

- 29 cycles displayed a depth, 0.8–1.9 s after the first sample of the new
  track or restart (median 0.9 s). In 28 of them Music logged the decoder
  record 0.06–1.2 s *before* that sample; one arrived 0.9 s after. The 9.5 s seen in the first capture did not recur, so it looks
  specific to starting from a stopped player.
- 3 track changes never displayed a depth, for 17, 13 and 12 s. These are the
  stall the user reported after pressing Back twice:
  - Back, Back: the first press restarts the current track and the second
    goes to the previous one, creating two decoder lifecycles 1.6 and 1.9 s
    apart. The selector treats lifecycles within 3 s as indistinguishable and
    withheld the depth for the whole track, twice. In one case both
    lifecycles were 16-bit, so nothing was actually ambiguous.
  - Returning to the following track: Music had started that item's lifecycle
    14 s earlier but logged its decoder report, and showed it as current, only
    at the boundary. The 5-second limit on early lifecycles rejected it.
- The fourth depth-less cycle was the first Back press itself, superseded
  after 0.5 s.

Changes to the selector (`Sources/DamonPlatform/MusicLogEvidence.swift`):
lifecycles within the margin withhold the depth only when they disagree; a
lifecycle already attributed to a different track is excluded, using Music's
per-instance lifecycle tag held in memory only; and the early limit applies
to the report time, not the start time. A wrong ledger attribution can
exclude valid evidence and may leave another lifecycle eligible, so the
result remains unverified.

Evidence: three regression tests use the real timings; and the whole session's
real log was replayed through the real parser and the new selector. The
replay matched the live result in all 29 cycles that had a depth, changed
none, and resolved the three stalls to 16, 24 and 16 bits, as the log shows.
The replay approximates the playback anchor, probe times and log visibility
and assigns track identities from the trace, and it is one session. The fix
has not yet been observed live. An existing hazard remains: if the previous
track was never attributed and the new track's report is not yet logged, a
restart of the previous track can still be selected for the new one.

**Follow-up with the changed selector.** Sixteen captures included seven
observed track changes. Six displayed a correlated depth 1.4–1.7 seconds
after the first accepted sample; one showed no depth throughout 106 seconds
of observation. Its probes found no eligible decoder record; the reason is
not yet known. These are small observational samples, not independent
verification of source depth, and they did not repeat the Back-twice
interaction. Device alignment remained unknown in the captured session.

## Research sequence and decision gates

The objective is to assess whether a local agent can eventually improve
sample-rate and bit-depth estimation using available evidence. Start with
diagnostic usefulness; format-estimation accuracy is a separate, later test.
Neither requires a production MCP integration. Keep the assistant off the
live detection and switching path throughout these experiments.

### A. First-track diagnostic pilot

1. Define “first track” as the first observed playing track after a documented
   session start, and record independently timestamped boundaries where
   available. Record starts, misses and delayed results, not just successes.
2. Audit which timestamps, probe outcomes and attribution decisions RateCue
   currently records. Where the source cannot distinguish a delayed Music
   event, log visibility, collector scheduling, attribution rejection or a
   probe failure, mark the cause **unknown**. Do not infer a root cause merely
   from absence of a log entry.
3. If necessary, design an opt-in bounded, redacted trace with a retention and
   deletion policy before instrumenting or collecting live data. Include
   clocks, provenance and availability times, observation gaps, epoch changes,
   failures, and explicit unknowns. Measure instrumentation overhead; obtain
   consent for live collection, playback changes or fixture use.
4. On the same held-out traces, compare a frozen deterministic rule-based
   diagnostic and the local agent. Independently review cited facts, supported
   cause versus hypothesis, appropriate unknowns and actionable next
   measurements. Count useful supported explanations, unsupported/confident
   claims, incorrect causes, and undecidable cases for both approaches.
   Record time spent, model runtime and evaluation cost.

**Gate:** before a broader trial, predeclare the pilot sample, scoring rubric
and success criteria; the agent must add demonstrable diagnostic value without
unsupported certainty or a measured RateCue regression. Too few labeled
cases or missing traces produce an inconclusive result, not a success claim.

### B. Blinded format-estimation evaluation

1. Build independently labeled cases for both rate and depth, including first
   track, same-rate 16/24 changes, mixed rates, pauses, restarts, rapid skips,
   delayed records, missing evidence and conflicts. A known local file alone
   does not establish an unrelated catalog rendition; mark cases without an
   independent active-rendition oracle unqualified and exclude them from
   accuracy claims.
2. Separate development and held-out cases by recording/session and fixture or
   track where feasible to reduce leakage and correlation. Freeze the model,
   prompt, available evidence, baseline, deadline, metrics and acceptance
   thresholds before scoring the held-out set. Deliver only observations
   available by that deadline; redact labels and future information.
3. Require a structured rate and depth estimate or explicit abstention, with
   cited evidence, uncertainty and decision time. Compare against both ground
   truth and RateCue's existing result on each identical case. Report counts
   and denominators separately for each field: correct, wrong, abstained,
   unavailable/missed and late; also report prediction coverage and conditional
   error among published predictions. An abstention is not a correct detection.
4. Report paired differences, uncertainty intervals and dependence or sampling
   limitations; do not treat repeated transitions as independent without
   justification. No finite test proves correctness. A zero-error binomial
   bound assumes independent representative cases; coverage and timing need
   their own reporting.

**Gate:** improvement over the existing engine must meet the predeclared
accuracy, coverage and timing criteria on held-out data, with resource and
audio-safety gates independently satisfied. Otherwise retain or stop the
experiment; do not promote the estimate.

### C. Live practicality and any later integration

After offline results justify it, test shadow mode without changing the display
or write path. Compare assistant-off/on first-track detection and switching
latency, misses, playback interruptions, memory pressure and swap. A live
shadow result is still experimental and cannot authorize a write. Consider
an opt-in display or a separately qualified switching proposal only after
the results, risks and safety constraints are reviewed. More capable hardware
is a possible follow-up only if the M2 is the demonstrated bottleneck.

## Initial adapter implementation

The following is a possible minimal read-only snapshot adapter, not a
prerequisite for the offline pilot. Its snapshot alone does not provide the
full trace needed for the research above. Do not expand its data exposure or
give the agent controls without a separate design and consent.

## 0. Establish a baseline and choose a host

1. Record the M2 Mac mini's macOS version, available storage, existing memory
   pressure, swap, and RateCue/Music behavior. Preserve the running app and
   user configuration; do not launch fixtures or change playback without consent.
2. Identify an already installed local assistant host that supports MCP stdio
   and can be configured to use a local model. Verify its protocol version,
   tool support, privacy, transcript retention, and outbound network behavior.
   Verify outbound traffic is blocked or absent for the actual host, runtime
   and model during the test; record unknowns. The host should show tool
   invocations and allow the user to deny them. Do not claim offline operation
   without testing it.
3. Evaluate one small, locally available quantized model first. Record model
   name, quantization, runtime, context size, memory footprint, and actual tool
   calling support. Trial fixed 2K and 4K context limits when supported; record
   unsupported configurations rather than assuming them. If no suitable host or
   model exists, stop at a mock-client
   proof of concept; obtain user approval before any installation or download.

**Gate:** reproducible environment and a confirmed host/model path, or an
explicitly limited mock-client experiment. No selection is assumed by design.

## 1. Prototype the read-only adapter

1. Choose a maintained SDK compatible with Swift/macOS and the selected host,
   or document a simpler implementation tradeoff. Pin dependencies only
   after confirming compatibility and licensing. Keep the executable separate
   from the menu app and existing deterministic policy.
2. Extract a shared snapshot reader/validator for use by the adapter and the
   current CLI, preserving CLI behavior including its environment override.
   The adapter uses the standard location only. Add file bounds, validation
   and redaction without claiming same-user file authentication.
3. Define a versioned allowlist-based output mapping. Do not copy free-form
   status or error strings into model-visible output. Explicitly identify the
   existing source schema and freshness checks; keep unknown values null.
4. Implement stdio negotiation and `ratecue_get_diagnostics` only. No listener,
   persistent cache, model runtime, background polling, or control tools.
5. Add the separate helper to the signed bundle and check packaging, signing,
   host launch, upgrades, disable and uninstall. Verify the existing app and
   CLI signing/permission behavior remains intact.

**Gate:** mock MCP client can initialize, list and call the tool and close
cleanly. The existing RateCue executable and its safety policy work unchanged.

## 2. Verify protocol, safety and usefulness

| Test | Expected outcome |
| --- | --- |
| Valid snapshot | Structured result accurately maps accepted depth, evidence, scores, provenance and timestamps; scores explicitly uncalibrated. |
| Unknown/conflicting/prior-only | No source depth is invented; conflict, absence and provisional priors remain distinct. |
| Stale, future-dated, missing, replaced process, unsupported schema/model, malformed or oversized file | Explicit error; no snapshot silently reused. Exercise clock changes, PID reuse and symlink rejection; document that PID checks do not authenticate the writer. |
| Invalid arguments, malformed JSON, unknown method, oversize input/output | Bounded protocol-compliant errors; server remains usable or exits cleanly. |
| Cancel, disconnect, unavailable or hung source | Correct protocol lifecycle, bounded cleanup, no RateCue termination; test unknown/finished cancellation IDs and newline-only stdout. |
| Adversarial strings and private data | Strings resembling tool instructions, paths, identifiers and secrets never bypass the allowlist; no raw diagnostics leak. |
| Read-only boundary | Tool list contains no writes or generic command facility; tests/spies show no playback, settings, permission, or hardware-write calls. |
| Host/model evaluation | Use the fixed evaluation described below; independently score unsupported certainty, false claims, leakage and useful explanations. |

Use synthetic fixtures and a mock host first. For live checks use the user's
existing playback without changing its state; distinguish snapshot observation
from an independent source-format oracle. A passing model evaluation does not
prove that all future answers are safe or accurate.

Before model selection, construct at least 40 labeled prompts spanning valid,
no-context, prior-only, conflict, stale/error, and instruction-injection
cases, including same-rate transitions. Freeze prompts, expected facts,
scoring rubric and host/model settings before running. For each configuration
report all case counts and independent human review results: proposed release
gate is zero privacy leaks, fabricated source formats, claims of calibrated
confidence, or stale data presented as current; at least 90% of cases must
correctly explain the supplied evidence or error. Failures or unavailable
human review leave the integration experimental. This is a finite sample,
not proof that the model cannot hallucinate.

**Gate:** automated tests pass, privacy and error behavior are demonstrated,
and live output preserves the same uncertainty as RateCue. Document known
attribution limitations rather than treating agent explanations as validation.

## 3. M2 / 8 GB measurements

Use the same Music queue, RateCue settings and device route for paired runs
where feasible. Record other workloads and avoid comparing unmatched workloads
as causal evidence. Measure:

1. Assistant off, host/model loaded but idle, and on-demand requests during
   normal playback. Use at least three paired runs of 15 minutes per condition,
   varying condition order where feasible; report order, ranges, peaks and
   failures. Fix and report prompt length, request cadence and context limit.
2. Per-process CPU and memory, system memory pressure and swap, and peak
   physical footprint; record cold model load time, warm inference time,
   context size, and tool/answer latency separately. Measure p95 adapter
   latency over at least 100 warm calls within the configured rate limit and
   report timeouts and cold starts. Sample pressure and swap every second.
3. Playback interruptions, RateCue detection and UI timing, and relevant
   existing product resource gates. An audible check is not a digital-integrity
   test. Do not claim a bit-perfect path from this exercise.
4. Evaluate proposed budgets in the specification; record the actual sampling
   tools, intervals, raw counts and environmental constraints. Where a live
   timing or audio oracle is unavailable, mark the gate unverified.

**Gate:** the proposed budgets and existing product gates pass on the reference
machine, or the feature remains experimental with the failed/unmeasured gates
documented. Report a usable smaller model only if actually measured.

## 4. Documentation and release decision

Document opt-in setup for the selected host, exactly what data is exposed,
offline verification, lifecycle, troubleshooting, and uninstall/disable steps.
State that host transcripts and model output are outside the adapter's control.
Report qualification separately for the adapter and for each host/model
configuration; an unverified host cannot inherit another host's privacy result.
Do not enable by default. Review MCP and host security assumptions before
release, and require explicit user consent before any future network transport,
history store, actions, or hardware-control capability is designed.

Potential later work—opt-in trace access, transition history, richer reports,
alternative transports or action tools—is outside v1 and needs its own privacy,
storage, authorization, resource and evidence specifications. It must not be
implied to exist today.
