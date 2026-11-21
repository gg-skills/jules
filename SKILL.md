---
name: jules
description: when running, monitoring, or troubleshooting Google Jules async coding sessions in a fleet — launching in parallel (≤15 concurrent / ≤100/day quota), approving plans, detecting stalled vs dead sessions, nudging with `jules send`, and harvesting PRs. Not for single interactive Jules sessions, not for the jules CLI itself (see the toolkit's `jules/` package), not for general async agents.
---

# jules — fleet operations playbook

> **Operational guidance.** Quotas (15 concurrent / 100 per day) and the
> requirePlanApproval transport bug are first-class concerns; if you skip
> this skill you will lose hours and quotas to silently-terminated sessions.

## When to use

**TRIGGER when:**
- The user wants to batch-convert N bash/python scripts to TypeScript, fix N
  similar bugs, or run any "do the same thing N times in N branches"
  workflow through Jules async sessions.
- A Jules session is parked in `AWAITING_PLAN_APPROVAL`, and you must decide
  whether to approve, reject, or `jules send` a clarification.
- The user asks "is it done?", "did they finish?", "is anything stuck?" for
  a fleet of Jules sessions — you need a poller that explains the state of
  each session without spamming the API.
- A session shows `state: IN_PROGRESS` but no new `progressUpdated`
  activities for 15+ minutes and you must decide whether to nudge, wait, or
  abort.
- The user asks to review the resulting PRs for convention adherence
  (eslint, sonarjs, JSDoc, `node:test`).

**SKIP when:**
- A single interactive Jules session is involved (one user, one prompt,
  watching it live).
- The question is about the `jules/` CLI surface itself (flags, auth,
  registry format) — open the source at `jules/src/cli.ts` /
  `jules/src/extension.ts` directly.
- The user asks about a different async-coding agent (Devin, Codex
  background, Factory, Aider, etc.).

## Hard rules (read these first)

These are non-obvious and have cost real sessions. Re-read before every
launch.

1. **`requirePlanApproval` defaults to `true` in interactive mode.**
   The `@google/jules-sdk`'s `session()` method ignores any
   `requirePlanApproval` field you set in its config and re-applies
   `config.requireApproval ?? true`. Net effect: every session without an
   explicit `requireApproval: false` lands in `AWAITING_PLAN_APPROVAL`
   and **silently terminates as `COMPLETED` with no PR** if not approved in
   time. Always pass `requireApproval` (true *or* false) explicitly. The
   toolkit's `jules/src/transport.ts` already encodes this fix; new
   transports must match it.

2. **Plan-approval timeout is server-side and silent.** A session that
   enters `AWAITING_PLAN_APPROVAL` and is not approved within ~7 minutes
   ends as `COMPLETED` with `state: COMPLETED` and `prUrl: null`. You
   cannot recover it — relaunch. Check the activity stream quickly:
   only `planGenerated` and never `progressUpdated` means the session died
   at the gate.

3. **Quota:** **≤15 concurrent active sessions**, **≤100 sessions per
   rolling 24h**. Exceed the daily cap and you will get 429s on `jules
   create`. Exceed the concurrent cap and queued tasks pile up while
   earlier ones chew the same budget.

4. **Activity counts lag; trust `updateTime` for liveness.** A session
   can be `IN_PROGRESS` with the same `activities.length` for 30+
   minutes while running a long `npm install` or compiling a large
   package. Cross-check `session.updateTime` — if it has not moved in 5
   minutes AND no new activity for 30+ minutes, the agent is stalled.
   Otherwise, leave it alone.

5. **PRs land with a specific shape.** Title is exactly
   `feat(<scope>): <imperative summary>` (per Jules' `autoPr` template,
   whatever you put in `--prompt`); URL is
   `https://github.com/<owner>/<repo>/pull/<N>`. Branches are
   `feat-<slug>-ts-<session-id>` (for short IDs) or `<session-id>`
   (for the long Google numeric IDs).

6. **The `jules send` nudge works on `AWAITING_USER_FEEDBACK` and
   `AWAITING_PLAN_APPROVAL` but is effectively a no-op on `IN_PROGRESS`**
   unless the agent's own progress loop has spun down. If the user
   reports "stuck", reach for `jules approve --session ID` first (in case
   the approval was lost), then `jules send` once, then escalate to
   relaunch — never loop on `send`.

## Quota & concurrency model

| Dimension | Limit | Source | When it kicks in |
|-----------|-------|--------|------------------|
| Concurrent active (`PLANNING` / `AWAITING_*` / `IN_PROGRESS`) | **15** | Jules API | 16th create returns 429 immediately |
| Daily creates (rolling 24h) | **100** | Jules API | 101st create within the window returns 429 |
| Plans per session | 1 (re-generable by send) | API | — |
| `progressUpdated` artifacts per session | unbounded but paginated (default 50) | API | — |

Live example (this session, 2026-07-28): launched 6 sessions in parallel —
all accepted, all hit `AWAITING_PLAN_APPROVAL`, approved in a single
`while`-loop pass. See the `launch-fleet` snippet in
[`references/launch-and-handle.md`](./references/launch-and-handle.md) for
the exact shell pattern.

## Approval workflow (the single biggest gotcha)

```
launch session
   ↓
state: QUEUED                                  (~0–30 s)
state: PLANNING                                (~30 s – 3 min)
planGenerated activity                         (+ planId, steps[])
state: AWAITING_PLAN_APPROVAL                  ← STOPS HERE
   ├── jules approve --session <id>            → state: IN_PROGRESS
   ├── DO NOTHING                              → state: COMPLETED, no PR (after ~7 min)
   └── jules send --prompt "..." + approve     → state: IN_PROGRESS (after ~30 s)
```

The minimax step — *always* approve within ~5 minutes of
`planGenerated` or relaunch.

Set `JULES_COMPANION_DIR` to the root of your Jules companion checkout
before running the fleet launcher:

```bash
cd "${JULES_COMPANION_DIR:?Set JULES_COMPANION_DIR to your companion checkout}" || exit
# launch with approval required
bin/launch-ts-conversions.sh --require-approval
# poll: first poll fires immediately; approve loop kicks off when state hits AWAITING_PLAN_APPROVAL
bin/launch-ts-conversions.sh --status
# batch approve (if user trusts the prompts)
while IFS=' ' read -r tool sid _; do
  jules approve --session "$sid"
done < .jules-ts-conversion-session-ids
```

For the *why*, read
[`references/approval-workflow.md`](./references/approval-workflow.md).

## Monitoring fleet states

State machine (full graph in [`references/state-machine.md`](./references/state-machine.md)):

```
QUEUED → PLANNING → AWAITING_PLAN_APPROVAL → IN_PROGRESS → COMPLETED
                ↘ AWAITING_USER_FEEDBACK ↗
                ↘ FAILED
```

Liveness check:

```
session.state in {IN_PROGRESS, PLANNING, AWAITING_USER_FEEDBACK} → session.updateTime
  ├─ moving within last 5 min  → alive
  ├─ stale 5–30 min             → likely long-running task (npm install, tsc); one nudge is OK
  └─ stale >30 min              → stalled; relaunch, do NOT loop nudges
session.state == AWAITING_PLAN_APPROVAL with no planApproved activity → relaunch (was never approved in time)
session.state == COMPLETED with prUrl == null                       → dead; relaunch
session.state == FAILED                                              → inspect activities[]; usually userMessaged plans were never sent; relaunch
```

Helper: `scripts/monitor.sh <ids-file>` (uses
`.jules-ts-conversion-session-ids` if present) prints one line per
session with state, activity count, last activity age, and PR URL.
Sample output:

```
  test_session (settings-cli)      IN_PROGRESS    acts=22  latest=12m ago  pr=no-pr
  skills-cli                       COMPLETED      acts=50  latest=2m ago   pr=https://github.com/.../pull/1
  auth-cli                         AWAITING_PLAN_APPROVAL               pr=no-pr   ← APPROVE ME
  jules-cli                        IN_PROGRESS    acts=22  latest=8m ago  pr=no-pr
```

## Nudging stalled sessions

```bash
# 1) Approve lost approvals (this is free, no quota cost)
jules approve --session $sid

# 2) Then nudge (only once per stuck interval — Jules ignores repeats faster than the agent loop)
jules send --session $sid --prompt "Continue. Emit a progressUpdated activity as the next concrete step."

# 3) If still stalled after 5 min, relaunch. Don't loop sends.
```

Templated nudge phrases (rotate to avoid rate-limit collisions on
identical text):
- "Continue with implementation. If you can split this into smaller steps, do so."
- "Resume from where you stopped. If context is exhausted, summarize the plan you've done so far and continue from step N."
- "Finish remaining steps in order. Mark each completed step with a progressUpdated event."

## Harvesting PRs

```bash
gh pr list --repo <owner>/<repo> --state open \
  --json number,title,headRefName,updatedAt,additions,deletions,changedFiles \
  | jq 'sort_by(.number)'
```

Then per PR:
- `gh pr view <N> --repo ...` for the description and review checklist
- Read the changed files to verify the conventions listed in the prompt
  are honored (eslint config, `node:test`, JSDoc, etc.)

PR review checklist for the bash → TypeScript pattern (carry across):
- `tsc --noEmit` runs clean in the new package (`bin/<tool>/tsconfig.json`)
- `node --test test/**/*.test.ts` (NOT vitest) — verify `package.json` test
  script
- Old bash moved to `bin/<tool>.bash`, shell stub at `bin/<tool>` delegates
  to `tsx cli.ts`
- `@fileoverview` + `@see` on every new file
- No `requirePlanApproval`-related API field names — must be
  `requireApproval`
- PR title matches the agreed convention (e.g.
  `feat(<TOOL>): convert bash to strict TypeScript`)

## Anti-patterns

- ❌ Launching 30 sessions in parallel because "they're free" — quota is
  real.
- ❌ Setting only `--require-approval` and walking away to do something
  else for 30 minutes — the approval window is roughly 7 minutes and is
  silent.
- ❌ Re-rendering `jules send` every minute on a stalled session to "wake
  it up" — Jules' own loop will queue messages faster than you can drain
  them.
- ❌ Treating `state: IN_PROGRESS` + unchanged `activities.length` for
  10 minutes as "dead" — long `npm install`s regularly take this long.
  Check `updateTime`.
- ❌ Keeping dead sessions in the local registry (`.jules-ts-conversion-session-ids`)
  past 24 hours — they will eventually confuse future polls because the
  API still returns them at their final state, and `--status` shows them
  forever. Prune after PR merge or formal abandon.

## Quick commands

```bash
cd "${JULES_COMPANION_DIR:?Set JULES_COMPANION_DIR to your companion checkout}" || exit
# launch a fleet from your companion checkout
bin/launch-ts-conversions.sh --require-approval   # 6 sessions in parallel
bin/launch-ts-conversions.sh --auto-approve       # 6 in parallel, auto-approve plans
bin/launch-ts-conversions.sh --status             # poll current

# raw equivalents
jules create --repo OWNER/REPO --branch main --auto-pr --require-approval --prompt "..."
jules approve --session <id>
jules send --session <id> --prompt "Continue."
jules pull --session <id>          # final PR + diff + suggested commit message
jules list --limit 20 --state IN_PROGRESS

# inline poll (cheapest check)
curl -s "https://jules.googleapis.com/v1alpha/sessions/$sid" \
  -H "X-Goog-Api-Key: $JULES_API_KEY" | jq '{state, prUrl: .outputs[0].pullRequest.url}'
```

## Operational examples (this rollout)

These timings came from a six-session Bash-to-TypeScript rollout
with the companion fleet launcher in `--require-approval` mode. The
session and tool identifiers are illustrative.

| Session | Tool | Launch → first activity | Approved → IN_PROGRESS | IN_PROGRESS → COMPLETED |
|---------|------|----:|----:|----:|
| example-1 | skills-cli | 90 s | <1 min | 30 min (PR #1 opened) |
| example-2 | auth-cli | 60 s | <1 min | *stalled at 6 acts; nudge at 12 min unstuck it* |
| example-3 | jules-cli | 60 s | <1 min | long-running, 60+ min |
| example-4 | tools-cli | 60 s | <1 min | long-running, 60+ min |
| example-5 | continue-cli | 60 s | <1 min | long-running, 60+ min |
| example-6 | settings-cli (test) | 60 s | <1 min | *stalled at 21 acts for 35 min, unstuck by nudge* |

Lessons encoded in the prompts and the launcher:
- Keep the test runner (`node:test`) and the project’s shared ESLint
  config in the launcher’s prompt templates to reuse the same conventions
  across sessions.
- The companion launcher's `--require-approval` is the only safe
  mode for launching >1 at once — auto-approve silently wastes quota on
  re-launches when plans turn out to be wrong.
- The companion launcher’s `--status` mode calls `jules status --session $sid`
  and falls back to REST when the CLI’s state cache is stale.

## Companion artefacts

- [`references/approval-workflow.md`](./references/approval-workflow.md) — deep dive on
  the requirePlanApproval transport bug + how the fix in
  `jules/src/transport.ts` keeps every new session path-safe.
- [`references/monitoring.md`](./references/monitoring.md) — the
  `monitor.sh` script anatomy, GraphQL-style REST query patterns,
  `updateTime`-vs-`activities` liveness in detail.
- [`references/launch-and-handle.md`](./references/launch-and-handle.md) —
  end-to-end fleet lifecycle (launch → poll → approve → nudge → harvest
  → review) with copy-pasteable shell.
- [`references/state-machine.md`](./references/state-machine.md) — full
  state graph with transition triggers and what each pair of adjacent
  states means in quota terms.

## Cross-references

- [Git submodules](https://github.com/gg-skills/git-submodules) — for managing
  individual skill repositories as submodules.
- Apply the SonarJS cognitive-complexity threshold of 30 in Bash-to-TypeScript
  conversion prompts.
- Review TypeScript symbol names in new packages after PRs land.
- Reference your project’s shared ESLint config in the conversion prompts.

## Working directory

Set `JULES_COMPANION_DIR` to the root of your Jules companion checkout.
The transport source is at `$JULES_COMPANION_DIR/jules/src/transport.ts`.
If you use the pi extension, configure it to load from your companion
checkout.
