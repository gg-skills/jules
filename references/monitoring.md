# Monitoring a Jules fleet

> The poller, the REST shapes, the liveness-vs-stall heuristic, and the
> `monitor.sh` script in detail.

## What to poll

Two endpoints, both with `X-Goog-Api-Key: $JULES_API_KEY`:

```
GET /v1alpha/sessions/{id}                  ← single session
GET /v1alpha/sessions/{id}/activities       ← activity stream (paginated)
```

Plus the `jules` CLI sugar over them:

```
jules status --session <id>
jules list --limit <N> [--state <STATE>]    ← list, last N matching STATE
jules pull --session <id>                   ← final PR + diff + suggested commit message
```

Both endpoints are rate-limited; the
[`scripts/monitor.sh`](../scripts/monitor.sh) script polls as cheaply as
possible (one request per session per cycle) and is safe to run on a
`while true` 60 s cadence.

## Liveness vs stall

| `state` | `updateTime` (ago) | `activities.length` (Δ in 10 min) | Diagnosis |
|---|---|---|---|
| `IN_PROGRESS` | <2 min | any | **alive**, leave it alone |
| `IN_PROGRESS` | 2–10 min | any | **long task**, leave it alone (npm install, tsc, etc.) |
| `IN_PROGRESS` | >10 min | >0 delta | **stalled**, one nudge is OK |
| `IN_PROGRESS` | >30 min | 0 delta | **dead**, do not loop nudges — relaunch |
| `AWAITING_PLAN_APPROVAL` | any | 1 (= `planGenerated`) | normal — **approve me** |
| `AWAITING_PLAN_APPROVAL` | any | 1 + `userMessaged` (nudge) | the nudge didn't reach — try direct approval |
| `AWAITING_PLAN_APPROVAL` | any | 0 | already dead, relaunch |
| `COMPLETED` | — | last activity `planGenerated` only | died at gate, **relaunch** |
| `COMPLETED` | — | last activity `progressUpdated` | success, harvest PR |
| `FAILED` | — | last activity `progressUpdated` w/ error | inspect, may need relaunch |

The 30-min stall threshold matches the live observation from this
session:

```
2026-07-28T03:48 test_session (settings-cli) approved, first progress at 03:48:39
2026-07-28T03:48 jules-cli approved, last agent activity 03:54:55 (≈ 6 min later)
                ... then silent for 60+ minutes while running npm install + tsx setup
2026-07-28T04:14 test_session latest progress 04:14:54 — total ~26 min of "stalled" that was actually compiling
```

A 30-minute silent stretch in `IN_PROGRESS` is the rough cutoff for
"actually stalled" vs "long-running".

## The `monitor.sh` script

```bash
# install at $PREFIX/bin/monitor-jules or just run from this skill
scripts/monitor.sh /path/to/.jules-ts-conversion-session-ids
# or pass an ad-hoc ids file: one line per session "<tool> <sid> <url>"
```

It:

1. reads an ids file (format: `<tool> <sid> <url>` per line, blank lines OK)
2. for each `sid`, calls `GET /v1alpha/sessions/{id}` and
   `GET /v1alpha/sessions/{id}/activities?pageSize=100`
3. prints a single fixed-width line per session with state, activity
   count, last-activity age, and PR URL
4. exits 0 with a summary line (`X to approve, Y alive, Z stalled, W dead,
   V succeeded`)

Sample output (this session, after skills-cli PR landed):

```
  TOOL                       STATE                       ACTS  LATEST  PR
  test_session               IN_PROGRESS                   22  14m ago  no-pr
  skills-cli               COMPLETED                     50   2m ago  https://github.com/.../pull/1
  auth-cli                 AWAITING_PLAN_APPROVAL         7   1m ago  no-pr          ← APPROVE ME
  jules-cli                IN_PROGRESS                   22   8m ago  no-pr
  tools-cli                IN_PROGRESS                   44   6m ago  no-pr
  continue-cli             IN_PROGRESS                   49  14m ago  no-pr

1 to approve, 4 alive, 0 stalled, 0 dead, 1 succeeded
```

The "approve me" line is the integration point for the approval workflow
(see `references/approval-workflow.md`).

## Activity stream pagination

`GET /v1alpha/sessions/{id}/activities` is paginated with
`pageSize=<N>` and a `nextPageToken` in the response. For monitoring,
`pageSize=100` is enough — sessions rarely exceed that. If you see a
session with `activities.length` exactly equal to `pageSize`, switch
the script's `--page-size` to `200` and check if it bumps.

For a per-session paginator (used when investigating dead/failed
sessions), see `references/launch-and-handle.md` → "Investigating a
dead session".

## What the artifacts look like

Each `progressUpdated` activity carries:

```jsonc
{
  "createTime": "2026-07-28T03:49:54Z",
  "originator": "agent",
  "progressUpdated": {
    "title": "Created project structure for `settings-cli`, moving bash to .bash, ...",
    "artifacts": [
      {
        "changeSet": {
          "gitPatch": {
            "unidiffPatch": "diff --git a/bin/settings-cli b/bin/settings-cli\n...",
            "suggestedCommitMessage": "feat(settings-cli): ..."
          }
        }
      }
    ]
  }
}
```

The `unidiffPatch.length` correlates (roughly) with the amount of work
done between snapshots — it's a cheap "workload this tick" signal. The
`jules pull --session <id>` helper extracts the full last patch and PR
URL.

## When to escalate from monitor → abort

`monitor.sh` exits with non-zero if any session is `state=FAILED` or
`state=COMPLETED` with `prUrl=null` and `activities[-1].type == planGenerated`.
That's the *only* automatic abort condition. Stalls remain a soft warning.
