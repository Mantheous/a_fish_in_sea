import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agy_quota
import capacity
import llm_output
import opencode_quota
from rework_state import policy


class CapacityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.env = patch.dict(os.environ, AGENT_STATE_DIR=str(self.state),
                              AGENT_CODEX_SESSIONS=str(self.state / "sessions"))
        self.env.start()
        self.addCleanup(self.env.stop)
        self.now = 1794090000

    def window(self, used, elapsed=.8, seconds=604800):
        return dict(used_percent=used, starts_at=self.now - elapsed * seconds,
                    resets_at=self.now + (1 - elapsed) * seconds, observed_at=self.now)

    def test_pacing_targets_90_and_reserves_remaining_capacity(self):
        self.assertEqual("spare", capacity.pace("codex", {"weekly": self.window(40)}, self.now))
        self.assertEqual("ahead", capacity.pace("codex", {"weekly": self.window(80, .2)}, self.now))
        self.assertEqual("reserve", capacity.pace("codex", {"weekly": self.window(90)}, self.now))
        self.assertEqual("unknown", capacity.pace("codex", {}, self.now))

    def test_monthly_pacing_uses_billing_period(self):
        row = self.window(85, .95, seconds=30 * 86400)
        self.assertEqual("steady", capacity.pace("opencode", {"monthly": row}, self.now))
        row["used_percent"] = 60
        self.assertEqual("spare", capacity.pace("opencode", {"monthly": row}, self.now))

    def test_quota_preflight_preserves_rework_reserve(self):
        (self.state / "quota.json").write_text(json.dumps({"codex": {"weekly": self.window(91)}}))
        self.assertFalse(capacity.allowed("codex", "builder", self.now))
        self.assertFalse(capacity.allowed("codex", "harness", self.now))
        self.assertTrue(capacity.allowed("codex", "rework", self.now))
        (self.state / "cooldown-codex.json").write_text(json.dumps(dict(until=self.now + 300)))
        self.assertFalse(capacity.allowed("codex", "review", self.now))
        self.assertTrue(capacity.allowed("antigravity", "review", self.now))

    def test_stale_future_and_expired_observations_are_unknown(self):
        for changed in (dict(observed_at=self.now - 1801), dict(observed_at=self.now + 10),
                        dict(resets_at=self.now - 1), dict(used_percent=101)):
            self.assertIsNone(capacity.valid_window({**self.window(10), **changed}, self.now))
        self.assertIsNone(capacity.valid_window(None, self.now))

    def test_codex_ignores_conversation_content_and_handles_bad_rows(self):
        day = dt.datetime.fromtimestamp(self.now, dt.timezone.utc).strftime("%Y/%m/%d")
        root = self.state / "sessions" / day
        root.mkdir(parents=True)
        event = dict(type="event_msg", timestamp=self.now, payload=dict(type="token_count", rate_limits=dict(
            primary=dict(used_percent=20, window_minutes=300, resets_at=self.now + 500),
            secondary=dict(used_percent=60, window_minutes=10080, resets_at=self.now + 50000))))
        (root / "latest.jsonl").write_text('not json\n{"type":"response_item","secret":"never retain"}\n' + json.dumps(event))
        result = capacity.codex_snapshot(self.now)
        self.assertEqual(20, result["five_hour"]["used_percent"])
        self.assertNotIn("secret", json.dumps(result))

    def test_balancing_rotates_real_starts_and_keeps_quotas_separate(self):
        (self.state / "last-builder.json").write_text(json.dumps(dict(pool="codex")))
        (self.state / "quota.json").write_text(json.dumps({
            "codex": {"weekly": self.window(50)},
            "antigravity": {"weekly": self.window(40)},
            "antigravity-3p": {"weekly": self.window(30)},
        }))
        result = capacity.plan(self.now)
        self.assertEqual("antigravity", result["exports"]["FISH_LLM_BUILDER_BACKEND"])
        self.assertEqual("gemini-3.8-flash-high", result["exports"]["FISH_LLM_BUILDER_MODEL"])
        self.assertEqual(1800, result["exports"]["AGENT_DISCOVER_MIN_INTERVAL_S"])
        self.assertEqual("antigravity-3p", capacity.pool_for("antigravity", "claude-opus-4-6-thinking"))

    def test_agy_status_callback_retains_no_identity_or_text(self):
        with patch("time.time", return_value=self.now):
            agy_quota.ingest(dict(email="private", conversation_title="private",
                quota={"gemini-weekly": dict(remaining_fraction=.6, reset_time=self.now + 40000)}))
        result = json.loads((self.state / "agy-quota.json").read_text())
        self.assertEqual(40, result["gemini-weekly"]["used_percent"])
        self.assertNotIn("private", json.dumps(result))
        self.assertEqual(40, capacity.snapshots(self.now)["antigravity"]["weekly"]["used_percent"])

    def test_go_monthly_start_clamps_end_of_month(self):
        result = opencode_quota.normalize(dict(usage=dict(monthly=dict(percent=85,
            resetsAt="2026-03-31T10:00:00Z"))), self.now)
        start = dt.datetime.fromtimestamp(result["monthly"]["starts_at"], dt.timezone.utc)
        self.assertEqual((2026, 2, 28), (start.year, start.month, start.day))
        self.assertEqual(85, result["monthly"]["used_percent"])

    def test_rework_escalates_and_keeps_top_tier_without_a_human_stop(self):
        for rounds in (0, 1, 2, 3, 4, 5, 20):
            comments = [dict(body="<!-- agent-rework -->") for _ in range(rounds)]
            comments.append(dict(body="Verdict: changes-requested\n<!-- agent-review --> sha=abc tier=0"))
            count, tier, adjudicate = policy(comments, "abc")
            self.assertEqual(rounds, count)
            self.assertEqual(min(2, rounds // 2), tier)
            self.assertEqual(int(tier > 0), adjudicate)
            comments[-1]["body"] = f"<!-- agent-review --> sha=abc tier={tier}"
            self.assertEqual(0, policy(comments, "abc")[2])
            self.assertEqual(1, policy(comments, "new-sha")[2])

    def test_failed_structured_result_never_becomes_a_verdict(self):
        with self.assertRaises(ValueError):
            llm_output.extract("antigravity", json.dumps(dict(status="ERROR", response="Verdict: pass")))
        with self.assertRaises(ValueError):
            llm_output.extract("opencode", '{"type":"error"}')
        rows = [dict(type="text", part=dict(text="starting")), dict(type="step_start"),
                dict(type="text", part=dict(text="Verdict: pass"))]
        self.assertEqual("Verdict: pass", llm_output.extract("opencode", "\n".join(map(json.dumps, rows))))


if __name__ == "__main__":
    unittest.main()
