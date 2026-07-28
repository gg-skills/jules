#!/usr/bin/env bash
# @fileoverview Launch N Jules sessions in parallel from a TSV of
# prompts. Saves the resulting session ids to the local ids file
# (`.jules-fleet-ids` by default).
#
# USAGE
#   scripts/launch-fleet.sh [OPTIONS] PROMPTS_TSV
#   scripts/launch-fleet.sh --auto-approve prompts.tsv   # skip --require-approval
#
# PROMPTS_TSV format
#   tool<TAB>prompt_file_path
#   per line. Blank lines and # comments OK.
#
# OUTPUT
#   .jules-fleet-ids in the same directory you ran the script from (or
#   wherever JULES_IDS_FILE points).
#   Format: <tool><TAB><sid><TAB><url>
#
# EXIT CODES
#   0  every launch received a session id
#   1  at least one launch failed (mixed)

set -uo pipefail

# --- config ----------------------------------------------------------------

AUTO_APPROVE=0
while [[ "${1:-}" == --* ]]; do
	case "$1" in
		--auto-approve) AUTO_APPROVE=1; shift ;;
		--require-approval) AUTO_APPROVE=0; shift ;;
		--ids-file) shift; JULES_IDS_FILE="$1"; shift ;;
		--help|-h)
			cat <<EOF
launch-fleet.sh — launch N Jules sessions in parallel

USAGE
  scripts/launch-fleet.sh [OPTIONS] PROMPTS_TSV

OPTIONS
  --auto-approve        Skip --require-approval (fire-and-forget)
  --require-approval    Default; require explicit approval per plan
  --ids-file PATH       Override the .jules-fleet-ids path
                        (default: \$PWD/.jules-fleet-ids or \$JULES_IDS_FILE)

PROMPTS_TSV
  Tab-separated: <tool>\\t<path/to/prompt.txt> per line.

REQUIRES
  - jules CLI in PATH or JULES_BIN set
  - JULES_API_KEY in env
EOF
			exit 0
			;;
		*) echo "launch-fleet.sh: unknown option: $1" >&2; exit 1 ;;
	esac
done

PROMPTS_TSV="${1:-}"
if [[ -z "$PROMPTS_TSV" || ! -f "$PROMPTS_TSV" ]]; then
	echo "launch-fleet.sh: PROMPTS_TSV required and must exist ($PROMPTS_TSV)" >&2
	exit 2
fi

IDS_FILE="${JULES_IDS_FILE:-${PWD}/.jules-fleet-ids}"
JULES_BIN="${JULES_BIN:-$(command -v jules)}"
if [[ -z "$JULES_BIN" ]]; then
	echo "launch-fleet.sh: jules CLI not in PATH" >&2
	exit 2
fi

if [[ -z "${JULES_API_KEY:-}" ]]; then
	if [[ -f "$HOME/.config/giaco/secrets.zsh" ]]; then
		# shellcheck disable=SC1090
		source "$HOME/.config/giaco/secrets.zsh"
	fi
fi

if [[ -z "${JULES_API_KEY:-}" ]]; then
	echo "launch-fleet.sh: JULES_API_KEY is not set" >&2
	exit 2
fi

# --- per-row launch --------------------------------------------------------

> "$IDS_FILE"

declare -a pids=()
fail_count=0

while IFS=$'\t' read -r tool prompt_file; do
	[[ -z "$tool" || "$tool" == \#* ]] && continue
	if [[ ! -f "$prompt_file" ]]; then
		echo "launch-fleet.sh: missing prompt file: $prompt_file (skipping $tool)" >&2
		continue
	fi
	(
		approval_flag=""
		if [[ $AUTO_APPROVE -eq 0 ]]; then
			approval_flag="--require-approval"
		fi
		response=$("$JULES_BIN" create \
			--repo "${JULES_REPO:-$(git config --get remote.origin.url | sed 's#.*github.com[:/]##; s#\.git$##')}" \
			--branch "${JULES_BRANCH:-main}" \
			--auto-pr \
			$approval_flag \
			--prompt "$(cat "$prompt_file")" 2>&1)
		sid=$(printf "%s" "$response" | jq -r '.id // empty' 2>/dev/null)
		url=$(printf "%s" "$response" | jq -r '.url // empty' 2>/dev/null)
		if [[ -z "$sid" || "$sid" == "null" ]]; then
			printf "  %-25s FAILED  response=%s\n" "$tool" "$(printf "%s" "$response" | head -1)" >&2
			exit 1
		fi
		printf "  %-25s %s  %s\n" "$tool" "$sid" "$url"
		printf "%s\t%s\t%s\n" "$tool" "$sid" "$url" >> "$IDS_FILE"
	) &
	pids+=($!)
done < "$PROMPTS_TSV"

for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		fail_count=$((fail_count + 1))
	fi
done

echo
echo "ids file: $IDS_FILE"
if (( fail_count > 0 )); then
	echo "$fail_count launches failed"
	exit 1
fi

if (( AUTO_APPROVE == 0 )); then
	echo
	echo "Next: scripts/monitor.sh $IDS_FILE    # poll for AWAITING_PLAN_APPROVAL"
	echo "Then: jules approve --session <sid>  # per session"
fi
