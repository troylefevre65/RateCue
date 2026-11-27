#!/usr/bin/env python3
"""Scores local models on synthetic first-track traces whose mechanism is known by construction.

This measures whether a model can read a trace and apply the documented decision list. It is a
necessary-condition check on generated data, not evidence about real playback or format accuracy.
"""

import argparse
import http.client
import importlib.util
import json
import math
import random
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("local_agent", Path(__file__).with_name("local-agent.py"))
agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agent)

DEADLINE = 10_000
RETRY_GAPS = (0, 250, 750, 1_500, 3_000, 6_000, 12_000)
RATES = (44_100, 48_000, 88_200, 96_000, 176_400, 192_000)
SEEDS = {"dev": 1_000, "heldout": 2_000}


def build(category, rng):
    """Returns (trace, key event indices). One anomaly is injected per trace."""
    items = []

    def add(at, event, key=False):
        items.append((at, len(items), event, key))

    def sample(start, state, rate=None, took=None, key=False):
        at = start + (took or rng.randint(15, 70))
        event = {"kind": "sample", "collectionStartMilliseconds": start, "availableAtMilliseconds": at,
                 "state": state, "disposition": "used", "trackChanged": False, "processChanged": False}
        if rate:
            event["reportedRateHz"] = rate
        add(at, event, key)
        return at

    rate, depth = rng.choice(RATES), rng.choice((16, 24))
    idle = rng.choice(("stopped", "paused", "unavailable"))
    cadence = 1_000 if idle == "unavailable" else 500
    add(2, {"kind": "display"})
    add(3, {"kind": "alignment", "alignmentState": "idle"})
    clock = 0
    for _ in range(rng.randint(8, 30) if category == "insufficientTrace:idle" else rng.randint(3, 20)):
        clock = sample(clock, idle) + cadence + rng.randint(1, 15)
    if category == "insufficientTrace:idle":
        return finish(items, rng), set()

    rate_delay = rng.randint(10_500, 16_000) if category == "musicRateReportedLate" else 0
    add(clock + 20, {"kind": "epoch"})
    boundary = sample(clock, "playing", None if rate_delay else rate)
    add(boundary + 3, {"kind": "display"})
    stall = rng.randint(10_500, 15_000) if category == "observationStalled" else 0
    # Earliest time the existing engine could start a log probe: it needs a reported rate and a free monitor.
    ready = boundary + max(rate_delay + 400 if rate_delay else 0, stall)
    align_at = boundary + 5 if stall else ready + 5

    mode = "failed" if category == "deviceAlignmentFailed" else rng.choice(("aligned", "aligned", "off", "monitorOnly"))
    if rate_delay:
        add(boundary + 4, {"kind": "alignment", "alignmentState": "unknown"})
    if mode in ("off", "monitorOnly"):
        add(align_at, {"kind": "alignment", "alignmentState": mode, "targetRateHz": rate})
    else:
        add(align_at, {"kind": "alignment", "alignmentState": "aligning", "targetRateHz": rate})
        add(align_at + (rng.randint(2_000, 6_000) if mode == "failed" else rng.randint(300, 900)),
            {"kind": "alignment", "alignmentState": mode, "targetRateHz": rate}, key=mode == "failed")

    nothing = lambda: ("noSelection", rng.choice((0, 0, rng.randint(1, 6))), 0)
    ambiguous = lambda: ("noSelection", rng.randint(4, 8), rng.randint(2, 4))
    selected = ("selected", rng.randint(3, 6), rng.randint(1, 3))
    if category in ("noDelay", "deviceAlignmentFailed", "musicRateReportedLate", "observationStalled"):
        outcomes = [nothing() for _ in range(rng.choice((0, 0, 1, 2, 3)))] + [selected]
    elif category == "logQueryFailed":
        outcomes = rng.choice(([("failed",), selected], [("failed",), ("failed",)], [nothing(), ("failed",), selected]))
    elif category == "logEvidenceLate":
        outcomes = [nothing() for _ in range(rng.choice((6, 7)))] + [selected]
    elif category == "logEvidenceAmbiguous":
        outcomes = [nothing() for _ in range(rng.randint(0, 2))] + [ambiguous() for _ in range(8)]
    elif category == "noMatchingLogEvidence":
        outcomes = [nothing() for _ in range(8)]
    else:  # insufficientTrace:short
        outcomes = [nothing() for _ in range(8)]
    outcomes = outcomes[:8]

    end = boundary + (rng.randint(2_000, 7_000) if category == "insufficientTrace:short" else rng.randint(14_000, 30_000))
    start, failures, shown = ready + rng.randint(110, 350), 0, None
    # A scripted selection always happens; otherwise the capture simply ends when it ends.
    completes = outcomes[-1][0] == "selected" and category != "insufficientTrace:short"
    for attempt, outcome in enumerate(outcomes, 1):
        done = start + rng.randint(150, 900)
        if completes and outcome[0] == "selected":
            end = max(end, done + rng.randint(1_500, 6_000))
        if start > end and not completes:
            break
        add(start, {"kind": "probeStarted", "attempt": attempt})
        if done > end and not completes:
            break
        event = {"kind": "probeCompleted", "attempt": attempt, "probeOutcome": outcome[0]}
        if outcome[0] != "failed":
            event.update(parsedEventCount=outcome[1], eligibleEventCount=outcome[2])
        key = {
            "logQueryFailed": outcome[0] == "failed",
            "logEvidenceLate": True,
            "logEvidenceAmbiguous": outcome[0] == "noSelection" and outcome[2] > 0,
            "noMatchingLogEvidence": True,
        }.get(category, False)
        if outcome[0] == "selected":
            event.update(depth=depth, selectedLogWallOffsetMilliseconds=boundary - rng.randint(0, 4_000))
            shown = done + rng.randint(5, 40)
            add(shown, {"kind": "display", "depth": depth, "depthSource": "correlation"})
        add(done, event, key)
        if outcome[0] == "selected" or attempt == 8:
            break
        if outcome[0] == "failed":
            failures += 1
            start = done + (12_000 if failures == 1 else 57_000)
        else:
            start = done + RETRY_GAPS[attempt - 1] + rng.randint(20, 300)

    clock = boundary + rng.randint(40, 90)
    if stall:
        clock = sample(clock, "playing", rate, took=stall, key=True) + rng.randint(20, 60)
    while clock < end:
        late = rate_delay and clock < boundary + rate_delay
        if rate_delay and not late and rate_delay != -1:
            add(clock + 10, {"kind": "epoch"})
            rate_delay = -1
        clock = sample(clock, "playing", None if late else rate, key=bool(late)) + 300 + rng.randint(1, 25)
    trace = finish(items, rng)
    keys = {index for index, item in enumerate(sorted(items)) if item[3]}
    if category == "musicRateReportedLate":
        keys.add(next(i for i, e in enumerate(trace["events"]) if e.get("state") == "playing"))
    return trace, keys


def finish(items, rng):
    events, playback = [], 0
    for at, _, event, _ in sorted(items):
        if event["kind"] == "epoch":
            playback += 1
        events.append({**event, "atMilliseconds": at, "playbackGeneration": playback, "routeGeneration": 1})
    return {"schemaVersion": 2, "clockBasis": "processUptimeRelativeToFirstRetainedEvent",
            "sessionBoundary": "captureStartNotListeningSession",
            "endedAtMilliseconds": events[-1]["atMilliseconds"] + rng.randint(20, 400),
            "bounded": False, "preRollTruncated": rng.random() < 0.5, "events": events}


CATEGORIES = (
    "noDelay", "logQueryFailed", "logEvidenceLate", "logEvidenceAmbiguous", "noMatchingLogEvidence",
    "musicRateReportedLate", "observationStalled", "deviceAlignmentFailed",
    "insufficientTrace:idle", "insufficientTrace:short",
)


def wilson(successes, total, z=1.96):
    if not total:
        return (0.0, 1.0)
    p = successes / total
    centre = p + z * z / (2 * total)
    margin = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))
    return ((centre - margin) / (1 + z * z / total), (centre + margin) / (1 + z * z / total))


def ollama(method, path, body=None):
    """Ollama-only housekeeping (loaded size, unload); a no-op for other server types."""
    if agent.API != "ollama":
        return {}
    connection, prefix = agent.connect()
    try:
        connection.request(method, prefix + path, json.dumps(body) if body is not None else None,
                           {"Content-Type": "application/json"})
        return json.loads(connection.getresponse().read() or b"{}")
    finally:
        connection.close()


def swap_megabytes():
    text = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    return float(text.split("used = ")[1].split("M")[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", choices=SEEDS, default="dev")
    parser.add_argument("--per-category", type=int, default=2)
    parser.add_argument("--models", default="", help="Comma-separated models; append +think to enable thinking")
    agent.add_server_options(parser)
    parser.add_argument("--out", type=Path, help="Write per-case results as JSON")
    parser.add_argument("--export-cases", type=Path, metavar="DIR",
                        help="Write instructions.md and cases.jsonl so any other model can answer the same cases")
    parser.add_argument("--score-answers", type=Path, metavar="FILE", action="append", default=[],
                        help="Score a JSONL file of {id, answer} produced elsewhere; repeatable")
    parser.add_argument("--show", action="store_true", help="Print every wrong or invalid answer")
    args = parser.parse_args()
    agent.apply_server_options(args)

    cases = []
    with tempfile.TemporaryDirectory() as directory:
        for position, category in enumerate(CATEGORIES):
            for repeat in range(args.per_category):
                seed = SEEDS[args.split] + position * 100 + repeat
                trace, keys = build(category, random.Random(seed))
                path = Path(directory) / "trace.json"
                path.write_text(json.dumps(trace))
                assessment = agent.assess_trace(path, DEADLINE)
                cases.append({"seed": seed, "category": category, "label": category.split(":")[0], "keys": keys,
                              "assessment": assessment, "baseline": agent.rule_hypothesis(assessment)})
    agreed = sum(case["baseline"] == case["label"] for case in cases)
    rows = [len(case["assessment"]["timeline"]) for case in cases]
    print(f"{args.split}: {len(cases)} cases; rule baseline matches the generator label on {agreed}/{len(cases)}; "
          f"timeline rows median {statistics.median(rows):.0f}, max {max(rows)}")
    for case in cases:
        if case["baseline"] != case["label"]:
            print(f"  baseline mismatch seed {case['seed']}: {case['label']} -> {case['baseline']}")

    if args.export_cases:
        args.export_cases.mkdir(parents=True, exist_ok=True)
        (args.export_cases / "instructions.md").write_text(
            agent.SYSTEM_PROMPT + "\n\nAnswer each case as one JSON object with exactly these fields, in this order:\n"
            + json.dumps(agent.ANSWER_SCHEMA["required"]) + "\nRow fields are an integer or null. displayedDepth is one of "
            + json.dumps(agent.OUTCOMES) + ". mechanism is one of " + json.dumps(list(agent.MECHANISMS)) + ".\n"
        )
        with (args.export_cases / "cases.jsonl").open("w") as file:
            for case in cases:
                file.write(json.dumps({"id": case["seed"], "case": agent.build_messages(case["assessment"])[1]["content"]}) + "\n")
        print(f"Exported {len(cases)} unlabeled cases to {args.export_cases}")

    report = {"split": args.split, "cases": len(cases), "baselineCorrect": agreed, "models": {}}
    external = []
    for path in args.score_answers:
        answers = {}
        for line in path.read_text().splitlines():
            if line.strip():
                entry = json.loads(line)
                answers[entry["id"]] = entry["answer"]
        external.append((path.stem, answers))
    local = [(spec, None) for spec in filter(None, args.models.split(","))]
    for spec, answers in local + external:
        model, think = spec.removesuffix("+think"), spec.endswith("+think")
        swap_before, results, loaded = swap_megabytes(), [], None
        for case in cases:
            started = time.time()
            try:
                if answers is None:
                    answer = agent.explain_assessment(case["assessment"], model=model, think=think, keep_alive="5m")
                elif case["seed"] in answers:
                    answer = agent.check_answer(case["assessment"], answers[case["seed"]])
                else:
                    raise agent.AgentError("No answer was supplied for this case.")
            except (agent.AgentError, OSError, ValueError, http.client.HTTPException) as error:
                answer = {"mechanism": None, "error": str(error), "rows": {}, "misread": []}
            if answers is None and loaded is None:
                loaded = next((m.get("size") for m in ollama("GET", "/api/ps").get("models", [])), None)
            cited = {index for index in answer["rows"].values() if index is not None}
            results.append({
                "seed": case["seed"], "category": case["category"], "label": case["label"],
                "predicted": answer["mechanism"], "seconds": round(time.time() - started, 2),
                "misread": answer["misread"], "citedKey": bool(case["keys"] & cited) if case["keys"] else None,
                "evidence": answer.get("evidence"), "error": answer.get("error"),
            })
        if answers is None:
            ollama("POST", "/api/generate", {"model": model, "keep_alive": 0})
        correct = sum(r["predicted"] == r["label"] for r in results)
        invalid = sum(r["predicted"] is None for r in results)
        low, high = wilson(correct, len(results))
        valid = [r for r in results if r["predicted"] is not None]
        clean = sum(not r["misread"] for r in valid)
        keyed = [r for r in valid if r["citedKey"] is not None]
        seconds = [r["seconds"] for r in results]
        print(f"\n{spec}: {correct}/{len(results)} correct ({correct / len(results):.0%}, 95% CI {low:.0%}-{high:.0%}); "
              f"{len(results) - correct - invalid} wrong, {invalid} invalid; "
              f"every row read correctly in {clean}/{len(valid)} valid answers; "
              f"cited a key event in {sum(r['citedKey'] for r in keyed)}/{len(keyed)} keyed answers; "
              + ("answers supplied from a file" if answers is not None else
                 f"seconds median {statistics.median(seconds):.1f}, max {max(seconds):.1f}; "
                 + ("" if loaded is None else f"loaded {loaded / 1e9:.1f} GB; ")
                 + (f"swap {swap_before:.0f} -> {swap_megabytes():.0f} MB" if agent.server_is_local()
                    else "remote server")))
        confusion = {}
        for r in results:
            if r["predicted"] != r["label"]:
                confusion[(r["label"], r["predicted"])] = confusion.get((r["label"], r["predicted"]), 0) + 1
                if args.show:
                    print(f"  seed {r['seed']} {r['category']} -> {r['predicted']} misread={r['misread']}: {r['evidence'] or r['error']}")
        for (label, predicted), count in sorted(confusion.items(), key=lambda item: -item[1]):
            print(f"  {count}x {label} answered as {predicted}")
        report["models"][spec] = {"correct": correct, "invalid": invalid, "results": results}
    if args.out:
        args.out.write_text(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
