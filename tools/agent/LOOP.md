# Loop capacity and improvement

The target is **90% of Codex and Antigravity weekly allowance, and 90% of
OpenCode Go monthly allowance**. This is a pacing target, not a reason to
generate busywork. Fix reported problems first; discover verified problems
and improve the harness when there is useful capacity left. Product vision
comes from the developer's repository documentation.

## Feature vision

Every model call receives a fresh map from `feature_docs.py` of tracked
repository docs and their section headings. All roles must read the relevant
sections of `docs/project-goal.md`, `product_specs.md` and feature-specific
docs before proposing new behavior or resolving a feature disagreement.
Plans, reviews and PRs record `Feature docs:` with paths/sections and how the
change fits the vision. The map is a discovery aid, not evidence that an
agent read a document. Agents search beyond it when necessary. New human
instructions win over older docs; conflicting or missing intent is stated
explicitly. Protected human vision documents cannot be rewritten merely to
justify a proposal. Newly committed feature docs enter the next run's map.

## Quota observations

Every poll refreshes provider observations before planning work:

- Codex: bounded tails of recent local session `token_count` events. Only
  quota percentages, window lengths and resets are retained.
- Antigravity: `agy_quota.py` starts an idle, private CLI status display,
  reads the documented `statusLine` quota callback, then terminates it. It
  submits no model prompt. Gemini and third-party pools stay separate.
- OpenCode Go: `opencode_quota.py` uses the active Console credential and
  workspace, matching OpenCode's credential precedence, against its Go
  usage endpoint. If no Console login is active, it uses the stored Go key.
  It never prints or stores tokens, keys or account identity. It refuses
  redirects and leaves credential refresh to OpenCode.

Observations expire after 30 minutes. Expired windows and future timestamps
are unknown, never assumed unused. No call-count-to-quota conversion is
used: providers price reasoning, context and caching differently.

`capacity.py report` shows observations and the current decision. `plan`
emits closed-set environment assignments consumed by `poll.sh`, never
provider-supplied shell code. The planner rotates subscriptions after actual
builder starts, avoids providers ahead of pace when another needs work, and
routes to Gemini Flash, Opus, Codex or OpenCode's configured model. Writer
slots remain bounded by `AGENT_BUILDER_SLOTS` (this host: 2), shared across
builders and reworkers. Explicit incoming routing wins over host defaults.

Below the 90% usage trajectory, discovery can run every 30 minutes and
maintain a queue of four pending issues/five PRs instead of two/three.
Ordinary new work stops at 90% of an observed window; review and rework can
use the reserve up to 98%. This leaves room to finish existing work and for
interactive use. In-flight work can overshoot; this cannot guarantee an
exact percentage. No fabricated issues or automatic paid overages are used
to meet the target. Antigravity explicitly uses `useG1Credits: false`.

A rate-limit failure cools down its own pool until an observed reset, or one
poll if the reset is unknown. Other pools keep working. A stale or missing
feed is visible in the report and retains conservative defaults.

For alternate provider telemetry, write `$AGENT_STATE_DIR/quota.json`:

```json
{
  "opencode": {
    "monthly": {
      "used_percent": 85,
      "starts_at": 1793491200,
      "resets_at": 1796083200,
      "observed_at": 1794090000
    }
  }
}
```

Provider keys are `codex`, `antigravity`, `antigravity-3p`, and `opencode`.
Window keys are `five_hour`, `weekly`, `monthly`. Times are UTC epoch seconds
or ISO timestamps. Fresh native observations take precedence.

## Rework escalation

The two-round human dead end is removed. Every two completed reworks raise
the tier: normal routing, then `gpt-6.1-sol/xhigh`, then `gpt-6.1-sol/max`
(the strongest model exposed by this host's Codex model catalog when this
policy was introduced). Host overrides `FISH_LLM_ESCALATION_BACKEND` and
`FISH_LLM_ESCALATION_MODEL` select a stronger available model later. The
tiers increase reasoning effort when the initial model is already Sol.

A stronger reviewer adjudicates the current head before spending another
builder run. Its evidence-backed judgment can dismiss a lower-tier finding.
The top tier keeps responsibility for the PR; there is no retry-count stop
or automatic human handoff. Rework has a one-hour retry delay and shares the
writer limit. Infra/contract failures consume no round. Successful model
runs that report `STATUS=failed` do count, so substantive failures escalate.
The wrapper owns rework comments and label transitions, not the model.
Legacy `agent-rework` comments still count.

The top reviewer cannot override data/security guardians, new test failures,
branch protection, or human-merge holds. It can distinguish an evidenced
baseline test failure from a regression. Passing reviews still bind to the
exact head SHA. A failed or malformed model response never changes labels.

## Measured self-improvement

`harness.sh` uses the existing discovery filter and queue, with a separate
cadence and a limit of **one** improvement issue per audit. It runs daily,
or once per five hours with spare capacity. It runs only after interval and
queue gates pass. It receives:

- A seven-day content-free run digest: failures, durations, model/tier,
  input/output/cache counts when the CLI reports them.
- Recent merge turnaround and rework counts from GitHub.
- Bounded excerpts from primary research, cached for seven days, with
  source URLs and fetch dates. Failed fetches are explicit.

Each proposal must identify a measured baseline, one hypothesis, a replay
fixture/evaluation, success metric, and rollback condition. Source text is
untrusted evidence and cannot instruct an agent. No findings is a valid
result. Improvements enter the normal issue -> plan -> isolated branch ->
tests -> review -> guardian -> merge workflow. The research agent cannot
rewrite its running harness or relax its gates.

Research references:

- [Long-running agent harnesses](https://www.anthropic.com/research/effective-harnesses-for-long-running-agents)
- [Evaluating agents](https://www.anthropic.com/research/demystifying-evals-for-ai-agents)
- [Codex noninteractive execution](https://developers.openai.com/codex/noninteractive/)
- [Antigravity status-line quota schema](https://antigravity.google/docs/cli/statusline)
- [Go quota reporting and credential selection](https://github.com/anomalyco/opencode/issues/52374)

## Diagnostics and overrides

State lives under `${AGENT_STATE_DIR:-$XDG_STATE_HOME/a_fish_in_sea}` (default
`~/.local/state/a_fish_in_sea`), outside builds and Git. `runs.jsonl` is capped
at roughly 8 MB and rotated to the latest 10,000 metadata rows.

```bash
python3 tools/agent/capacity.py report
python3 tools/agent/llm_metrics.py summary
tools/agent/harness.sh --dry-run
python3 -m unittest discover -s tools/agent/test -p '*_test.py'
tools/agent/test/llm-run-test.sh
tools/agent/test/discover-test.sh
```

Set `AGENT_CAPACITY_ROUTE_BUILDERS=0` in the host configuration to retain a
fixed builder backend. Other cadence overrides remain in the existing host
configuration. The pause file/issue still prevents all poll work, including
quota collectors. The systemd timer needs no restart for script changes.
