# Approval workflow — `requirePlanApproval` gotcha

> The single biggest landmine when launching >1 Jules session at a time.
> Set `JULES_COMPANION_DIR` to your Jules companion checkout before running the launcher.

## TL;DR

The `@google/jules-sdk`'s interactive entry point `jules.session(config)`
silently defaults `requirePlanApproval` to **`true`** for any config that
omits or incorrectly spells the field. Net effect: every plan waits for
explicit approval and the session times out as `COMPLETED` (no PR) after
~7 minutes. Always pass `requireApproval` (true or false) explicitly.

## The bug, in code

```typescript
// jules/src/transport.ts — original (broken)
async create(opts: CreateOpts): Promise<Session> {
  const config = {
    prompt: opts.prompt,
    source: { github: opts.repo, baseBranch: opts.branch ?? "main" },
    autoPr: opts.autoPr ?? false,
    requirePlanApproval: opts.requireApproval ?? false,  // ❌ SDK ignores this field
  };
  const session = await jules.session(config);           // ❌ SDK reads `requireApproval`
  ...
}

// SDK behaviour (vendor `node_modules/@google/jules-sdk/dist/index.mjs`)
// const body = await this._prepareSessionCreation(config);
// await this.apiClient.request("sessions", {
//   method: "POST",
//   body: {
//     ...body,
//     automationMode: ...,
//     requirePlanApproval: config.requireApproval ?? true   // ⚠️ defaults to TRUE for `session()`
//   }
// });
```

If you write `requirePlanApproval` in the config, the SDK reads
`config.requireApproval` instead — gets `undefined` — and defaults to
`true`. Every session without an active approver dies at the gate.

## The fix

```typescript
// jules/src/transport.ts — fixed
async create(opts: CreateOpts): Promise<Session> {
  // The SDK's session() reads `config.requireApproval` (NOT
  // `requirePlanApproval`). If unset, it defaults to `true` for
  // interactive sessions, which means every plan waits for explicit
  // approval and silently times out otherwise. Always pass an explicit
  // value so the caller controls the behavior.
  const config = {
    prompt: opts.prompt,
    source: { github: opts.repo, baseBranch: opts.branch ?? "main" },
    autoPr: opts.autoPr ?? false,
    requireApproval: opts.requireApproval ?? false,    // ✅ correct field name
  };
  const session = await jules.session(config);
  ...
}
```

## What happens without the fix

```
$ jules create --repo OWNER/REPO --branch main --auto-pr --prompt "Convert X to TS"

{
  "id": "6164447402217052381",
  "state": "QUEUED",
  "prUrl": null
}

(3 minutes later)
planGenerated activity: {planId, steps[...]}   ← state: AWAITING_PLAN_APPROVAL

(7 minutes later, no approval)
state: COMPLETED
prUrl: null
lastActivity: null
```

Inspection of `session.activities[]` shows only `planGenerated` (and
possibly my later attempts via `session.approve()` that were API-rejected
because the session had already auto-ended).

## Recovery options

| Session state | What's reversible |
|---------------|---|
| `AWAITING_PLAN_APPROVAL` | ✅ `jules approve --session <id>` (within ~7 min) |
| `COMPLETED` with `prUrl: null` after ~7 min | ❌ relaunch as a fresh session |
| `COMPLETED` with `prUrl: <url>` | ✅ PR is live — review it |

## CLI: the `--require-approval` flag

The `jules create` CLI exposes both:

| Flag | What it sets | When to use |
|------|------|------|
| (omit) | `requireApproval: false` (via transport fix) | Fire-and-forget; you trust every plan. |
| `--require-approval` | `requireApproval: true` | Batch launches: you want to review plans before execution. **Default for any fleet of >1 sessions.** |
| `--auto-approve` | explicit override to `requireApproval: false` | Symmetric to `--require-approval`. |

`bin/launch-ts-conversions.sh --require-approval` is the **default
mode** for any launch of >1 session — always review plans first.

## Pattern: review + batch-approve

```bash
cd "${JULES_COMPANION_DIR:?Set JULES_COMPANION_DIR to your companion checkout}" || exit
# 1. launch
bin/launch-ts-conversions.sh --require-approval

# 2. wait for plans (~30s – 3 min after launch)
sleep 90
bin/launch-ts-conversions.sh --status    # shows AWAITING_PLAN_APPROVAL for ready ones

# 3a. inspect each pending plan (option)
while IFS=' ' read -r tool sid _; do
  curl -s "https://jules.googleapis.com/v1alpha/sessions/$sid/activities?pageSize=5" \
    -H "X-Goog-Api-Key: $JULES_API_KEY" \
  | jq -r '.activities[] | select(.planGenerated) | .planGenerated.plan.steps[] | "\(.title): \(.description)"'
done < .jules-ts-conversion-session-ids

# 3b. batch-approve (the common path for repetitive conversions)
while IFS=' ' read -r tool sid _; do
  jules approve --session "$sid"
done < .jules-ts-conversion-session-ids
```

## Common dismissal: "I'll just set `--auto-pr` and trust Jules."

`--auto-pr` only governs whether the PR is opened *once execution
finishes*. It does **not** gate plan approval. So `--auto-pr` without
approval management is a recipe for silently-completed sessions that
burn your quota.

## When to set `--require-approval` explicitly (not just implicit)

- Any launch of >1 session.
- Any launch where the prompt is novel (not templated).
- Any launch where the target repository has been recently renamed or
  default-branch-changed (a plan may pick the wrong base).
- Any launch where you care about *which* approach Jules takes
  (e.g. need to confirm port = 80 vs 443 before it builds half a repo).

## When auto-approve is safe

- Refactoring 50 similar files (rename, lint sweep, type-narrow).
- Bulk-imports of migration data into a project you own start-to-end.
- Re-running a templated prompt you have already greenlit once (the
  plans for "convert bash to TS" on a script you previously approved are
  ~identical and inspected-once is fine).

Anything outside that set: `--require-approval`.

## See also

- `references/monitoring.md` — how to spot a dying session from its
  activity stream (no `planApproved` = dead).
- `references/state-machine.md` — full state graph; specifically the
  `AWAITING_PLAN_APPROVAL → COMPLETED (without PR)` edge.
- `$JULES_COMPANION_DIR/jules/src/transport.ts` — the transport fix in your companion checkout.
- `bin/launch-ts-conversions.sh --help` — `--require-approval` /
  `--auto-approve` flags.
