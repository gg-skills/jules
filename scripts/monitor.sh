#!/usr/bin/env bash
# @fileoverview Fleet monitor — poll every session in an ids file and
# print one line per session with state, activity count, last-activity
# age, PR URL, and a flag if action is required.
#
# USAGE
#   scripts/monitor.sh [IDS_FILE]
#     IDS_FILE  Path to a 3-column TSV: <tool>\t<sid>\t<url>
#               Defaults to ${PWD}/.jules-fleet-ids (most common) or
#               $JULES_IDS_FILE. Blank lines and # comments are OK.
#
# EXIT CODES
#   0  all sessions alive OR completed-with-PR OR dead-but-known
#   1  any session is FAILED, OR COMPLETED-without-PR (loud fail so
#      cron / CI can flag it)
#   2  bad arguments (missing JULES_API_KEY, missing ids file)
#
# REQUIRES
#   - JULES_API_KEY in env (sourced from ~/.config/giaco/secrets.zsh or
#     wherever the kit expects it)
#   - curl, jq, python3
#
# OUTPUT (columns: tool, state, acts, last-age, pr, flag)
#   TOOL                                  STATE                       ACTS  LAST-AGE  PR                                                FLAG
#   test_session                          IN_PROGRESS                   22   14m ago  no-pr                                            (none)
#   giaco-skills                          COMPLETED                     50    2m ago  https://github.com/.../pull/1                     (succeeded)
#   giaco-auth                            AWAITING_PLAN_APPROVAL         7    1m ago  no-pr                                            ← APPROVE ME
#   giaco-jules                           IN_PROGRESS                   22    8m ago  no-pr                                            (none)
#   giaco-tools                           IN_PROGRESS                   44    6m ago  no-pr                                            (none)
#
# @see ../SKILL.md — how to interpret this output
# @see ../references/monitoring.md — liveness-vs-stall heuristic

set -uo pipefail

# --- config ----------------------------------------------------------------

IDS_FILE="${1:-${JULES_IDS_FILE:-${PWD}/.jules-fleet-ids}}"
API_BASE="https://jules.googleapis.com/v1alpha"
PAGE_SIZE=100

if [[ -z "${JULES_API_KEY:-}" ]]; then
	if [[ -f "$HOME/.config/giaco/secrets.zsh" ]]; then
		# shellcheck disable=SC1090
		source "$HOME/.config/giaco/secrets.zsh"
	fi
fi

if [[ -z "${JULES_API_KEY:-}" ]]; then
	echo "monitor.sh: JULES_API_KEY is not set (source ~/.config/giaco/secrets.zsh)" >&2
	exit 2
fi

if [[ ! -f "$IDS_FILE" ]]; then
	echo "monitor.sh: ids file not found: $IDS_FILE" >&2
	exit 2
fi

# --- per-session query -----------------------------------------------------

query_session() {
	local sid="$1"
	local raw
	raw=$(curl -fsS "${API_BASE}/sessions/${sid}" -H "X-Goog-Api-Key: ${JULES_API_KEY}" 2>/dev/null)
	if [[ -z "$raw" ]]; then
		printf "  %-45s %s\n" "$tool" "API_ERROR"
		return 1
	fi
	local state pr acts update_age
	state=$(printf "%s" "$raw" | jq -r '.state // "UNKNOWN"')
	pr=$(printf "%s" "$raw" | jq -r '.outputs // [] | map(select(.pullRequest)) | .[0].pullRequest.url // "no-pr"')

	# activities: simple 1-shot for monitoring; heavy pagination is in
	# references/launch-and-handle.md.
	local acts_json
	acts_json=$(curl -fsS "${API_BASE}/sessions/${sid}/activities?pageSize=${PAGE_SIZE}" \
		-H "X-Goog-Api-Key: ${JULES_API_KEY}" 2>/dev/null)
	if [[ -z "$acts_json" ]]; then
		acts_json='{"activities":[]}'
	fi

	acts=$(printf "%s" "$acts_json" | jq -r '.activities | length')
	# last activity age in minutes, 0 if none
	update_age=$(printf "%s" "$acts_json" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
acts = sorted(d.get('activities', []), key=lambda a: a.get('createTime', ''), reverse=True)
if not acts:
    print('-')
else:
    last = acts[0].get('createTime', '')
    try:
        dt = datetime.datetime.fromisoformat(last.replace('Z', '+00:00'))
        now = datetime.datetime.now(datetime.timezone.utc)
        delta = now - dt
        seconds = int(delta.total_seconds())
        if seconds < 60:
            print(f'{seconds}s ago')
        else:
            print(f'{seconds // 60}m ago')
    except Exception:
        print('-')
" 2>/dev/null)
	if [[ -z "$update_age" || "$update_age" == "None" ]]; then
		update_age="-"
	fi
	printf "  %-45s %-30s %4s  %-10s  %-50s  %s\n" "$tool" "$state" "$acts" "$update_age" "$pr" "$(flag_for_state "$state" "$acts_json" "$pr")"
}

flag_for_state() {
	local state="$1" acts_json="$2" pr="$3"
	case "$state" in
		AWAITING_PLAN_APPROVAL)
			printf "%s" "← APPROVE ME"
			;;
		COMPLETED)
			if [[ "$pr" == "no-pr" ]]; then
				# check if last activity is planGenerated -> silent death
				if printf "%s" "$acts_json" | jq -e '.activities | map(select(.planGenerated)) | length > 0 and (map(select(.progressUpdated)) | length == 0)' >/dev/null 2>&1; then
					printf "%s" "← DEAD (relaunch)"
				else
					printf "%s" "(unknown completion)"
				fi
			else
				printf "%s" "(succeeded)"
			fi
			;;
		FAILED)
			printf "%s" "← FAILED (inspect)"
			;;
		IN_PROGRESS)
			# stalled? (>30m no activity)
			local latest_age
			latest_age=$(printf "%s" "$acts_json" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
acts = sorted(d.get('activities', []), key=lambda a: a.get('createTime', ''), reverse=True)
if acts:
    last = acts[0].get('createTime', '')
    try:
        dt = datetime.datetime.fromisoformat(last.replace('Z', '+00:00'))
        now = datetime.datetime.now(datetime.timezone.utc)
        print(int((now - dt).total_seconds()))
    except: pass
")
			if [[ -n "$latest_age" ]] && (( latest_age > 1800 )); then
				printf "%s" "← STALLED (nudge or relaunch)"
			else
				printf "%s" ""
			fi
			;;
		*)
			printf "%s" ""
			;;
	esac
}

# --- main ------------------------------------------------------------------

printf "  %-45s %-30s %4s  %-10s  %-50s  %s\n" "TOOL" "STATE" "ACTS" "LAST-AGE" "PR" "FLAG"
printf -- "  %s\n" "$(printf -- '-%.0s' {1..180})"

approve_count=0
alive_count=0
stalled_count=0
dead_count=0
succeeded_count=0
error_count=0

# Support both tab- and space-separated input (tool, sid, url).
while read -r line; do
	[[ -z "$line" || "$line" == \#* ]] && continue
	# skip leading/trailing whitespace
	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	# split by tabs first; if only one field, fall back to spaces.
	if [[ "$line" == *$'\t'* ]]; then
		IFS=$'\t' read -r tool sid url <<< "$line"
	else
		read -r tool sid url <<< "$line"
	fi
	[[ -z "$tool" ]] && continue
	[[ -z "$sid" ]] && continue
	# capture stdout from function (state), but we want to keep the line together
	out=$(query_session "$sid")
	printf "%s\n" "$out"

	case "$out" in
		*"API_ERROR"*) error_count=$((error_count + 1)) ;;
		*"← APPROVE ME"*) approve_count=$((approve_count + 1)) ;;
		*"← STALLED"*) stalled_count=$((stalled_count + 1)) ;;
		*"← DEAD"*) dead_count=$((dead_count + 1)) ;;
		*"succeeded"*) succeeded_count=$((succeeded_count + 1)) ;;
	esac
done < "$IDS_FILE"

echo
echo "$approve_count to approve, $alive_count alive, $stalled_count stalled, $dead_count dead, $succeeded_count succeeded, $error_count errors"

# non-zero exit only on FAILED or silent-dead
if (( dead_count > 0 || error_count > 0 )); then
	exit 1
fi
exit 0
