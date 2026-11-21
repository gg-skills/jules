# Launch and handle — end-to-end

> The full lifecycle: how to launch a fleet, monitor it, approve plans,
> nudge stalls, and harvest PRs. With copy-pasteable shell.

## Lifecycle at a glance

```
1. PLAN         Decide: how many, what prompts, what approval mode
2. LAUNCH       jules create × N in parallel (via & + wait or scripts/launch-fleet.sh)
3. POLL         scripts/monitor.sh — exit non-zero on dead
4. APPROVE      jules approve × N (or --status + manual review)
5. MONITOR      long-running execution (10–60 min)
6. NUDGE        one shot per stuck session if monitor flags a stall
7. HARVEST      gh pr list + jules pull + review checklist
8. CLEANUP      prune dead sessions from local ids file
```

## Step 1 — plan

Decisions to make:

| Decision | Default | Override when |
|---------|--------|---------------|
| Number of sessions | min(workload, 15) | daily quota already partially spent |
| `--auto-pr` | yes | testing; you want PR only after manual git push |
| `--require-approval` | yes (for >1) | single templated conversion you trust |
| Branch | `main` (from prompt) | the repo's primary isn't `main` |
| Title prefix | conventional (your prompt controls the PR title) | n/a |

Daily quota ledger:

```
spent today = $(jules list --limit 100 | jq '.sessions | length')
remaining   = 100 - spent_today
allowed     = min(15 - in_flight, remaining)
```

If `allowed < workload`, split the work into phases or push to
tomorrow. **Do not assume "it's small, I'll just launch 20 and the
API will truncate it to 15"** — the 16th call returns 429 *after*
charging your create-quota, so you'll wake up to 16 dead sessions
in your registry.

## Step 2 — launch

Set `JULES_COMPANION_DIR` to your Jules companion checkout and run its launcher:

```bash
cd "${JULES_COMPANION_DIR:?Set JULES_COMPANION_DIR to your companion checkout}" || exit
bin/launch-ts-conversions.sh --require-approval   # 6 parallel sessions
```

Or, for the raw `jules create` equivalent:

```bash
sessions=()
while read tool prompt_file; do
  jules create --repo OWNER/REPO --branch main --auto-pr \
    --require-approval \
    --prompt "$(cat "$prompt_file")" &
  sessions+=($!)
done < prompts.tsv
wait
```

(Child jobs write to `jules-launch-$tool.XXXXXX.log` via the toolkit's
launcher; otherwise pipe to a temp file in `mktemp`.)

Capture session IDs to a local registry:

```bash
# format: <tool> <sid> <url>
> .jules-fleet-ids
while IFS=$'\t' read -r tool prompt_file; do
  response=$(jules create --repo OWNER/REPO --branch main --auto-pr \
    --require-approval --prompt "$(cat "$prompt_file")" 2>&1)
  sid=$(printf "%s" "$response" | jq -r '.id')
  url=$(printf "%s" "$response" | jq -r '.url')
  printf "%s\t%s\t%s\n" "$tool" "$sid" "$url" >> .jules-fleet-ids
done < prompts.tsv
```

## Step 3 — poll

```bash
scripts/monitor.sh .jules-fleet-ids
```

The script prints one line per session with status flags (`← APPROVE ME`,
`← STALLED`, `← DEAD`). **Don't close the terminal without a final
`monitor.sh` run** that returns zero — that means everyone is
either approved-and-running, or done (with PR or confirmed-relaunch).

## Step 4 — approve

```bash
# batch (if you trust every prompt)
while IFS=$'\t' read -r tool sid url; do
  state=$(jules status --session "$sid" 2>/dev/null | jq -r '.state // ""')
  if [[ "$state" == "AWAITING_PLAN_APPROVAL" ]]; then
    jules approve --session "$sid"
  fi
done < .jules-fleet-ids

# per-plan inspection
while IFS=$'\t' read -r tool sid url; do
  state=$(jules status --session "$sid" 2>/dev/null | jq -r '.state // ""')
  if [[ "$state" != "AWAITING_PLAN_APPROVAL" ]]; then continue; fi
  printf "\n=== %s (%s) ===\n" "$tool" "$sid"
  curl -s "https://jules.googleapis.com/v1alpha/sessions/$sid/activities?pageSize=5" \
    -H "X-Goog-Api-Key: $JULES_API_KEY" \
  | jq -r '.activities[] | select(.planGenerated) | .planGenerated.plan.steps[] | "  - \(.title): \(.description)"'
done < .jules-fleet-ids
# then ask the user / approve manually
```

## Step 5 — long-running monitor

```bash
# once a minute for as long as you need
watch -n 60 'scripts/monitor.sh .jules-fleet-ids'
```

Or:

```bash
while true; do
  scripts/monitor.sh .jules-fleet-ids
  sleep 60
done
```

Default `sleep 60` is fine; sessions don't tick faster than that.

## Step 6 — nudge

```bash
# scripts/nudge.sh SID "msg"  (or call jules send directly)
nudge() {
  local sid="$1" msg="$2"
  jules send --session "$sid" --prompt "$msg"
}
nudge "$sid" "Continue. Emit a progressUpdated activity as the next concrete step."
```

Rules of engagement:

- One nudge per stuck interval. The agent has a small message queue;
  duplicate prompts get deduplicated or, worse, ignored.
- Use a rotating set of three or four templated phrases (see SKILL.md
  → "Nudging stalled sessions") to avoid rate-limiting collisions on
  identical text.
- After a nudge, wait 5 min before considering the session dead.

## Step 7 — harvest

```bash
gh pr list --repo OWNER/REPO --state open \
  --json number,title,headRefName,updatedAt,additions,deletions,changedFiles \
  | jq 'sort_by(.number)'

# per PR
gh pr view 1 --repo OWNER/REPO --json files,additions \
  | jq '.files[] | select(.path | startswith("bin/")) | .path'
```

`jules pull --session <id>` extracts:

```
{
  "id": "6164447402217052381",
  "state": "COMPLETED",
  "url": "https://jules.google.com/session/6164447402217052381",
  "prUrl": "https://github.com/.../pull/1",
  "prTitle": "feat(settings-cli): convert bash to strict TypeScript",
  "prDescription": "...",
  "diffSummary": { "fileCount": 12, "bytes": 8731 },
  "suggestedCommitMessage": "..."
}
```

## Step 8 — cleanup

```bash
# remove dead/completed sessions from registry
grep -v -E '(COMPLETED|FAILED)' .jules-fleet-ids > .jules-fleet-ids.tmp
mv .jules-fleet-ids.tmp .jules-fleet-ids
```

Dead sessions:

- Have `prUrl: null` after the workflow finished.
- Are candidates for relaunch (see SKILL.md → "Common dismissal").
- Are not auto-removed by the API — that's the consumer's job.

## Investigating a dead session

```bash
# pull *all* activities (not just last 50)
while : ; do
  resp=$(curl -s "https://jules.googleapis.com/v1alpha/sessions/$sid/activities?pageSize=100&pageToken=$next" \
    -H "X-Goog-Api-Key: $JULES_API_KEY")
  echo "$resp" | jq '.activities[]'
  next=$(echo "$resp" | jq -r '.nextPageToken // ""')
  [[ -z "$next" ]] && break
done > "$sid.activities.jsonl"

# look at the activity types (planGenerated / planApproved / progressUpdated / userMessaged / ...)
jq -r '. | [.createTime, .originator, (keys | select(.[2] != null))[2]] | @tsv' "$sid.activities.jsonl"
```

If the only agent activity is `planGenerated`, the session died at the
gate; relaunch with proper approval. If it ends with `progressUpdated`
and contains an error message in the title or description, that may
help diagnose what to fix in the prompt before relaunching.

## See also

- `SKILL.md` — top-level overview + the approval-workflow decision tree.
- `references/approval-workflow.md` — the `requirePlanApproval` bug in detail.
- `references/monitoring.md` — monitor.sh + liveness heuristic.
- `references/state-machine.md` — full state graph.
