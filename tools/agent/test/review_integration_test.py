"""Replay the real reviewer dispatcher with fake GitHub, tmux and models."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ReviewIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dir = self.root / "tools/agent"
        self.dir.mkdir(parents=True)
        source = Path(__file__).resolve().parents[1]
        for name in ("review.sh", "rework_state.py"):
            shutil.copy(source / name, self.dir / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, AGENT_REPO=str(self.root), AGENT_STATE_DIR=str(self.root / "state"),
                        PATH=str(self.bin) + ":" + os.environ["PATH"],
                        AGENT_LLM_RUN=str(self.bin / "llm"), FIXTURE_ROOT=str(self.root))
        self.script("gh", r'''#!/usr/bin/env python3
import json,os,sys,pathlib
root=pathlib.Path(os.environ['FIXTURE_ROOT']); a=sys.argv[1:]
with (root/'calls').open('a') as h: h.write(json.dumps(a)+'\n')
if a[:2]==['pr','list']:
 print(json.dumps([dict(number=900001,headRefName='agent/test',headRefOid='abc')]))
elif a[:2]==['pr','view']:
 field=a[a.index('--json')+1]
 if field=='labels': print((root/'labels').read_text())
 elif field=='comments':
  rows=json.loads((root/'comments').read_text())
  if '--jq' in a: print('\n'.join(r['body'] for r in rows))
  else: print(json.dumps(dict(comments=rows)))
 else: print(json.dumps(dict(number=900001,title='Test',body='',comments=[])))
elif a[:2]==['pr','diff']: print('diff --git a/tools/agent/poll.sh b/tools/agent/poll.sh\n+change')
elif a[:2]==['pr','comment']: (root/'verdict').write_text(a[a.index('--body')+1])
''')
        self.script("tmux", '''#!/usr/bin/env bash
if [ "$1" = ls ] || [ "$1" = has-session ]; then exit 1; fi
printf '%s\n' "$*" >>"$FIXTURE_ROOT/tmux"
''')
        self.script("git", '''#!/usr/bin/env bash
if [ "$1" = worktree ]; then
  printf 'worktree %s\nbranch refs/heads/agent/test\n' "$FIXTURE_ROOT"
fi
''')
        self.script("llm", '''#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >>"$FIXTURE_ROOT/llm"
if [ "${REVIEW_FAIL:-0}" = 1 ]; then exit 3; fi
printf 'Verdict: pass\nFix list: none\n'
''')
        label = self.dir / "label.sh"
        label.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$FIXTURE_ROOT/label-calls"\n')
        label.chmod(0o755)

    def script(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_review(self, rounds, tier=0, label="review:changes-requested", fail=False):
        rows = [dict(body="<!-- agent-rework -->") for _ in range(rounds)]
        rows.append(dict(body=f"Verdict: changes-requested\n<!-- agent-review --> sha=abc tier={tier}"))
        (self.root / "comments").write_text(json.dumps(rows))
        (self.root / "labels").write_text(label)
        env = dict(self.env, REVIEW_FAIL=str(int(fail)))
        result = subprocess.run([str(self.dir / "review.sh")], env=env, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        return result.stdout

    def test_two_rounds_trigger_stronger_adjudication_then_clear_rejection(self):
        self.run_review(2)
        self.assertIn("--tier 1", (self.root / "llm").read_text())
        self.assertIn("sha=abc tier=1", (self.root / "verdict").read_text())
        self.assertIn("remove review:changes-requested", (self.root / "label-calls").read_text())
        self.assertFalse((self.root / "tmux").exists())

    def test_failed_adjudication_never_lifts_verdict(self):
        self.run_review(4, fail=True)
        self.assertIn("--tier 2", (self.root / "llm").read_text())
        self.assertFalse((self.root / "label-calls").exists())
        self.assertFalse((self.root / "verdict").exists())

    def test_top_tier_rejection_gets_another_rework(self):
        self.run_review(6, tier=2)
        self.assertIn("rework-run.sh 900001 7 2", (self.root / "tmux").read_text())
        self.assertFalse((self.root / "llm").exists())

    def test_current_pass_does_not_require_an_escalation_marker(self):
        self.run_review(0, label="review:pass")
        self.assertFalse((self.root / "llm").exists())
        self.assertFalse((self.root / "tmux").exists())


if __name__ == "__main__":
    unittest.main()
