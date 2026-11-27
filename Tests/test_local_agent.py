import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


path = Path(__file__).resolve().parent.parent / "Scripts/local-agent.py"
spec = importlib.util.spec_from_file_location("local_agent", path)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class FakeClient:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.error = False

    def start(self):
        self.calls.append("start")

    def send(self, message):
        self.calls.append(message)

    def request(self, method, params):
        self.calls.append((method, params))
        if method == "initialize":
            return {"protocolVersion": "2025-11-25"}
        if method == "tools/list":
            return {"tools": [{"name": agent.TOOL}]}
        if method == "tools/call":
            return {"isError": self.error, "content": [{"type": "text", "text": "unknown"}],
                    "structuredContent": {"playbackState": "stopped"}}
        raise AssertionError(method)

    def close(self):
        self.closed = True


class LocalAgentTests(unittest.TestCase):
    def test_calls_only_the_read_only_tool_and_returns_model_response(self):
        client = FakeClient()
        tool_call = {"role": "assistant", "tool_calls": [
            {"function": {"name": agent.TOOL, "arguments": {}}}
        ]}
        with patch.object(agent, "MCPClient", return_value=client), patch.object(
            agent, "chat", side_effect=[tool_call, {"content": "Depth is unknown."}]
        ) as chat:
            self.assertEqual(agent.run("What is the depth?"), "Depth is unknown.")
        self.assertIn(("tools/call", {"name": agent.TOOL, "arguments": {}}), client.calls)
        self.assertTrue(client.closed)
        self.assertEqual(chat.call_count, 2)
        # The snapshot reaches the model once, not as both text and structured content.
        self.assertEqual(chat.call_args.args[0][-1]["content"], '{"playbackState":"stopped"}')

    def test_model_cannot_invoke_other_tools_or_bypass_tool_call(self):
        for reply in [
            {"role": "assistant", "content": "It is 24-bit."},
            {"tool_calls": [{"function": {"name": "playback", "arguments": {}}}]},
            {"tool_calls": [{"function": {"name": agent.TOOL, "arguments": {"path": "/tmp/x"}}}]},
        ]:
            client = FakeClient()
            with self.subTest(reply=reply), patch.object(agent, "MCPClient", return_value=client), patch.object(
                agent, "chat", return_value=reply
            ), self.assertRaises(agent.AgentError):
                agent.run("Check diagnostics")
            self.assertTrue(client.closed)
            self.assertFalse(any(isinstance(call, tuple) and call[0] == "tools/call" for call in client.calls))

    def test_tool_error_stops_before_model_answer(self):
        client = FakeClient()
        client.error = True
        reply = {"tool_calls": [{"function": {"name": agent.TOOL, "arguments": {}}}]}
        with patch.object(agent, "MCPClient", return_value=client), patch.object(
            agent, "chat", return_value=reply
        ) as chat, self.assertRaises(agent.AgentError):
            agent.run("Check diagnostics")
        self.assertEqual(chat.call_count, 1)
        self.assertTrue(client.closed)

    TIMELINE = [
        "#0-#3 -2000ms..-500ms 4 samples stopped rate=none used",
        "#4 +0ms sample playing rate=44100 used firstAcceptedPlayingSample",
        "#5 +300ms logProbe 1 started",
        "#6 +700ms logProbe 1 failed",
        "#7-#40 +900ms..+12600ms 34 samples playing rate=44100 used",
        "#41 +12800ms logProbe 2 selected parsed=3 eligible=1 depth=24",
        "#42 +12820ms display depth=24 source=correlation",
        "captureEnded +15000ms",
    ]

    def assessment(self):
        return {"diagnosticVersion": 2, "displayedDepth": "observedAfterDeadline", "firstPlayingEventIndex": 4,
                "rootCause": None, "ruleHypothesis": "logQueryFailed", "timeline": self.TIMELINE}

    def answer(self, **changes):
        rows = dict.fromkeys(agent.OBSERVATIONS)
        rows.update(firstAcceptedPlayingSampleRow=4, failedLogProbeRow=6, selectedLogProbeRow=41)
        return {**rows, "displayedDepth": "observedAfterDeadline", "mechanism": "logQueryFailed",
                "evidence": "Probe 1 failed.", **changes}

    def test_trace_goes_through_fixed_cli_and_model_readings_are_checked(self):
        process = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.assessment()).encode(), stderr=b"")
        replies = [
            self.answer(),
            # Cites a row that is not a failed probe, misses the selected probe, and miscopies the outcome.
            self.answer(failedLogProbeRow=5, selectedLogProbeRow=None, displayedDepth="inconclusive",
                        mechanism="insufficientTrace"),
        ]
        for reply, misread in zip(replies, ([], ["failedLogProbeRow", "selectedLogProbeRow", "displayedDepth"])):
            with patch.object(agent.subprocess, "run", return_value=process) as run, patch.object(
                agent, "chat", return_value={"content": json.dumps(reply)}
            ) as chat:
                _, rule, answer = agent.analyze_trace(Path("/private/trace.json"), 2000, model="qwen3:1.7b")
            self.assertEqual(rule, "logQueryFailed")
            self.assertEqual(answer["misread"], misread)
            self.assertEqual(answer["mechanism"], reply["mechanism"])
        self.assertEqual(run.call_args.args[0][-3:], ["--deadline-ms", "2000", "--timeline"])
        self.assertNotIn("/private/trace.json", str(chat.call_args))
        # The model must not be handed the rule's answer.
        self.assertNotIn("ruleHypothesis", str(chat.call_args))
        self.assertEqual(chat.call_args.kwargs["model"], "qwen3:1.7b")
        self.assertEqual(chat.call_args.kwargs["schema"], agent.ANSWER_SCHEMA)

    def test_invalid_structured_answers_are_rejected(self):
        process = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.assessment()).encode(), stderr=b"")
        for content in ["not json", json.dumps(self.answer(mechanism="solarFlare")),
                        json.dumps(self.answer(failedLogProbeRow="6"))]:
            with self.subTest(content=content), patch.object(agent.subprocess, "run", return_value=process), \
                 patch.object(agent, "chat", return_value={"content": content}), self.assertRaises(agent.AgentError):
                agent.analyze_trace(Path("trace.json"), 2000)

    def test_missing_required_row_is_rejected(self):
        for field in agent.OBSERVATIONS:
            answer = self.answer()
            del answer[field]
            with self.subTest(field=field), self.assertRaises(agent.AgentError):
                agent.check_answer(self.assessment(), answer)

    def test_external_answer_can_be_checked_without_a_local_model(self):
        process = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.assessment()).encode(), stderr=b"")
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            prompt, answer = Path(directory) / "prompt.json", Path(directory) / "answer.json"
            answer.write_text(json.dumps(self.answer(selectedLogProbeRow=None)))
            with patch.object(agent.subprocess, "run", return_value=process), patch.object(agent, "chat") as chat, \
                 patch("sys.stdout", output):
                with patch("sys.argv", ["local-agent.py", "--trace", "t.json", "--export-prompt", str(prompt)]):
                    self.assertEqual(agent.main(), 0)
                with patch("sys.argv", ["local-agent.py", "--trace", "t.json", "--check-answer", str(answer)]):
                    self.assertEqual(agent.main(), 0)
            chat.assert_not_called()
            exported = json.loads(prompt.read_text())
        self.assertEqual(exported["system"], agent.SYSTEM_PROMPT)
        self.assertNotIn("ruleHypothesis", exported["user"])
        checked = json.loads(output.getvalue()[output.getvalue().rindex('{\n  "assessment"'):])
        self.assertEqual(checked["agentHypothesis"]["misread"], ["selectedLogProbeRow"])
        self.assertIs(checked["agentAgreesWithRule"], True)

    def test_oversized_prompt_is_refused_and_cut_off_answer_is_an_error(self):
        with patch.object(agent.http.client, "HTTPConnection") as connection, self.assertRaises(agent.AgentError):
            agent.chat([{"role": "user", "content": "x" * 4 * agent.NUM_CTX}])
        connection.assert_not_called()
        with patch.object(agent.http.client, "HTTPConnection") as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = json.dumps({"message": {"content": "{"}, "done_reason": "length"}).encode()
            with self.assertRaises(agent.AgentError):
                agent.chat([{"role": "user", "content": "short"}])
            self.assertIs(json.loads(connection.return_value.request.call_args.args[2])["truncate"], False)

    def test_openai_compatible_server_gets_schema_and_its_reply_is_normalised(self):
        answer = json.dumps(self.answer())
        with patch.object(agent, "API", "openai"), patch.object(agent, "SERVER", "http://192.0.2.1:8080"), \
             patch.object(agent.http.client, "HTTPConnection") as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = json.dumps(
                {"choices": [{"message": {"content": answer}, "finish_reason": "stop"}]}
            ).encode()
            result = agent.explain_assessment(self.assessment(), model="some-model")
            self.assertEqual(connection.call_args.args[:2], ("192.0.2.1", 8080))
            method, path, payload, _ = connection.return_value.request.call_args.args
            self.assertEqual((method, path), ("POST", "/v1/chat/completions"))
            body = json.loads(payload)
            self.assertEqual(body["response_format"]["json_schema"]["schema"], agent.ANSWER_SCHEMA)
            self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
            self.assertNotIn("ruleHypothesis", payload)
            self.assertFalse(agent.server_is_local())
            agent.chat([{"role": "user", "content": "short"}], think=True)
            body = json.loads(connection.return_value.request.call_args.args[2])
            self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": True})
            response.read.return_value = json.dumps(
                {"choices": [{"message": {"content": "{"}, "finish_reason": "length"}]}
            ).encode()
            with self.assertRaises(agent.AgentError):
                agent.chat([{"role": "user", "content": "short"}])
        self.assertEqual(result["mechanism"], "logQueryFailed")
        self.assertEqual(result["misread"], [])

    def test_openai_tool_call_arguments_arrive_as_text(self):
        client = FakeClient()
        tool_call = {"role": "assistant", "tool_calls": [
            {"id": "call_1", "type": "function", "function": {"name": agent.TOOL, "arguments": "{}"}}
        ]}
        with patch.object(agent, "API", "openai"), patch.object(agent, "MCPClient", return_value=client), \
             patch.object(agent, "chat", side_effect=[tool_call, {"content": "Stopped."}]) as chat:
            self.assertEqual(agent.run("State?"), "Stopped.")
        self.assertEqual(chat.call_args.args[0][-1]["tool_call_id"], "call_1")
        tool_call["tool_calls"][0]["function"]["arguments"] = '{"path": "/tmp/x"}'
        with patch.object(agent, "API", "openai"), patch.object(agent, "MCPClient", return_value=FakeClient()), \
             patch.object(agent, "chat", return_value=tool_call), self.assertRaises(agent.AgentError):
            agent.run("State?")

    def test_cli_selects_model_and_reports_both_hypotheses(self):
        answer = {"mechanism": "noDelay", "evidence": "", "rows": {}, "misread": []}
        output = io.StringIO()
        with patch("sys.argv", ["local-agent.py", "--trace", "trace.json", "--model", "qwen3:1.7b"]), \
             patch("sys.stdout", output), \
             patch.object(agent, "analyze_trace", return_value=(self.assessment(), "logQueryFailed", answer)) as analyze:
            self.assertEqual(agent.main(), 0)
        analyze.assert_called_once_with(Path("trace.json"), 10_000, model="qwen3:1.7b")
        printed = json.loads(output.getvalue())
        self.assertEqual(printed["model"], "qwen3:1.7b")
        self.assertEqual(printed["ruleHypothesis"], "logQueryFailed")
        self.assertIs(printed["agentAgreesWithRule"], False)

    def test_bad_trace_and_timeout_never_reach_model(self):
        failures = [
            subprocess.CompletedProcess([], 1, stdout=b"", stderr=b"sensitive path"),
            subprocess.CompletedProcess([], 0, stdout=b"{}", stderr=b""),
            subprocess.TimeoutExpired("RateCue", 10),
        ]
        for failure in failures:
            with self.subTest(failure=failure), patch.object(
                agent.subprocess, "run", side_effect=[failure] if isinstance(failure, Exception) else None,
                return_value=failure
            ), patch.object(agent, "chat") as chat, self.assertRaises(agent.AgentError):
                agent.analyze_trace(Path("/private/trace.json"), 2000)
            chat.assert_not_called()


if __name__ == "__main__":
    unittest.main()
