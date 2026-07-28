# Jules session state machine

> The full state graph with transition triggers and quota implications.
> When in doubt, the state graph is the truth.

## State graph

```
                     ┌─── AWAITING_USER_FEEDBACK (paused for user)
                     │     ↑
                     │     │ user resumes via jules send
                     │     │
   QUEUED ────→ PLANNING ────→ AWAITING_PLAN_APPROVAL ──┐
                  │              │                      │
                  │              │ no approval in ~7 min │
                  │              └──────────────────────► COMPLETED (no PR) ⚠️
                  │                                     │
                  │                                     │ jules approve
                  │                                     ↓
                  │                                     │
                  └───→ IN_PROGRESS ←────────────────────┘
                            │
                            │ jules send (optional mid-task)
                            ↓
                          AWAITING_USER_FEEDBACK
                            │
                            │ user resumes
                            ↓
                          IN_PROGRESS
                            │
                            ├───→ COMPLETED (with PR) ✅
                            │
                            └───→ FAILED (with error message)
```

## States

| State | Origin | Duration typical | Quota |
|-------|--------|------------------|-------|
| `QUEUED` | just after `jules create` | 0–30 s | counts toward concurrent |
| `PLANNING` | API started generating plan | 30 s – 3 min | counts toward concurrent |
| `AWAITING_PLAN_APPROVAL` | plan generated, waiting | 0 – 7 min (silent timeout) | counts toward concurrent |
| `AWAITING_USER_FEEDBACK` | agent asked for clarification mid-task | variable | counts toward concurrent |
| `IN_PROGRESS` | plan approved / clarification received | 5 – 60 min | counts toward concurrent |
| `COMPLETED` (with PR) | PR opened, work accepted | terminal | free (released) |
| `COMPLETED` (no PR) | silent death at the gate | terminal | wasted |
| `FAILED` | unrecoverable error | terminal | wasted |

## Transitions in detail

### `QUEUED → PLANNING`

API picked up the session. No agent activity yet.

**Trigger:** server-side worker picks the task.

**Quota:** counts toward the 15-concurrent cap.

**Operator action:** none (just observe).

### `PLANNING → AWAITING_PLAN_APPROVAL`

Plan generated. The `planGenerated` activity appears with a `planId`
and `steps[]`. The session is now parked waiting for `jules approve`.

**Trigger:** agent publishes `planGenerated` activity.

**Quota:** still counts toward 15-concurrent.

**Operator action (default):** `jules approve --session <id>` within
~5 minutes. Approval within the next ~2 minutes is also fine; past
~7 minutes the session may already have transitioned to the dead
`COMPLETED (no PR)` state.

**Operator action (skip if trusted):** none — see SKILL.md
"Auto-approve" section.

### `AWAITING_PLAN_APPROVAL → COMPLETED (no PR)` ⚠️

Silent death. No user-actionable signal; you only discover it by
polling.

**Trigger:** API-side timeout (approximately 7 minutes after plan
generation, observed in this session).

**Quota:** wasted. Released only when the session is replaced by
a relaunch.

**Operator action:** relaunch the same prompt as a fresh session.
The original id is dead — do not try to re-approve.

### `AWAITING_PLAN_APPROVAL → IN_PROGRESS`

Approval received.

**Trigger:** `jules approve --session <id>` (or equivalent REST).

**Quota:** still counts toward 15-concurrent.

**Operator action:** none — monitor for next state transition.

### `IN_PROGRESS → COMPLETED (with PR)`

The happy path.

**Trigger:** agent pushes branch + opens PR via `--auto-pr`.

**Quota:** freed.

**Operator action:** harvest the PR (`gh pr view`, review checklist
in `SKILL.md`).

### `IN_PROGRESS → FAILED`

Unrecoverable error during execution. The `lastActivity` will be a
`progressUpdated` with an error description, OR the agent sent
messages the user didn't reply to (forcing a `FAILED` after some
idle timeout).

**Trigger:** server-side error or user-unanswered agent question.

**Quota:** wasted.

**Operator action:** inspect `lastActivity`; usually a fix in the
prompt or the target repo's state. Relaunch with the corrected
prompt as a fresh session.

### `IN_PROGRESS → AWAITING_USER_FEEDBACK`

Agent asked a clarifying question.

**Trigger:** agent believed its next step was ambiguous and
emitted a `userMessaged` activity.

**Quota:** still counts toward 15-concurrent.

**Operator action:** read the prompt; `jules send --session <id>
--prompt "<your answer>"`; session transitions back to
`IN_PROGRESS`.

## What the activity stream encodes

Each activity has:

```
{
  "createTime": ISO8601,
  "originator": "agent" | "user",
  // exactly one of:
  "planGenerated": { plan: { id, steps[] } },
  "planApproved":  {},
  "progressUpdated": { title, artifacts[{ changeSet: { gitPatch } }] },
  "userMessaged":  { prompt },
  "sessionCompleted": { prUrl, ... },
  "sessionFailed":  { reason, ... }
}
```

The CLI normalizes these via `jules/src/extension.ts`; the raw REST
shape uses different field names (`changeSet.gitPatch.unidiffPatch` is
the diff body, `changeSet.gitPatch.suggestedCommitMessage` is the
commit message).

## Edge case: two `planApproved` activities

If you call `jules approve --session <id>` twice (e.g. once
manually, once via a polling loop), you'll see two `planApproved`
activities. The session still transitions to `IN_PROGRESS` once.
Don't worry — it's idempotent at the state machine level.

## Edge case: nudges as `userMessaged`

`jules send --prompt "..."` always emits a `userMessaged` activity
(originator=user). The agent may interpret it as the answer to a
pending question, or simply queue it as a hint for the next
progress step. If the nudge phrase is the same across two nudges
in a row, the second is usually deduplicated.

## See also

- `SKILL.md` → "Liveness check" — the liveness table.
- `references/approval-workflow.md` — the `requirePlanApproval` bug.
- `references/monitoring.md` — how `monitor.sh` translates this graph
  into actionable flags.
