#!/usr/bin/env bash
# @fileoverview Send a follow-up nudge to a stalled Jules session.
# Uses one of four rotating template phrases so duplicate-nudge
# rate-limit collisions stay rare.
#
# USAGE
#   scripts/nudge.sh SID [MESSAGE]
#
# If MESSAGE is omitted, one of:
#   "Continue. Emit a progressUpdated activity as the next concrete step."
#   "Continue with implementation. If you can split this into smaller steps, do so."
#   "Resume from where you stopped. If context is exhausted, summarize the plan you've done so far and continue from step N."
#   "Finish remaining steps in order. Mark each completed step with a progressUpdated event."
# is chosen at random.
#
# EXIT CODES
#   0  the nudge was accepted (state: AWAITING_USER_FEEDBACK or higher)
#   1  the session is in FAILED state — no point nudging
#   2  bad arguments

set -uo pipefail

SID="${1:-}"
MSG="${2:-}"

if [[ -z "$SID" ]]; then
	echo "nudge.sh: SID required" >&2
	echo "  usage: nudge.sh SID [MESSAGE]" >&2
	exit 2
fi

# --- config ----------------------------------------------------------------

if [[ -z "${JULES_API_KEY:-}" ]]; then
	if [[ -f "$HOME/.config/giaco/secrets.zsh" ]]; then
		# shellcheck disable=SC1090
		source "$HOME/.config/giaco/secrets.zsh"
	fi
fi

if [[ -z "${JULES_API_KEY:-}" ]]; then
	echo "nudge.sh: JULES_API_KEY is not set" >&2
	exit 2
fi

JULES_BIN="${JULES_BIN:-$(command -v jules)}"
if [[ -z "$JULES_BIN" ]]; then
	echo "nudge.sh: jules CLI not in PATH (set JULES_BIN=/path/to/jules)" >&2
	exit 2
fi

# --- pick a template if no message provided --------------------------------

if [[ -z "$MSG" ]]; then
	TEMPLATES=(
		"Continue. Emit a progressUpdated activity as the next concrete step."
		"Continue with implementation. If you can split this into smaller steps, do so."
		"Resume from where you stopped. If context is exhausted, summarize the plan you've done so far and continue from step N."
		"Finish remaining steps in order. Mark each completed step with a progressUpdated event."
	)
	MSG="${TEMPLATES[$((RANDOM % ${#TEMPLATES[@]}))]}"
fi

# --- check session state first --------------------------------------------

raw=$(curl -fsS "https://jules.googleapis.com/v1alpha/sessions/$SID" \
	-H "X-Goog-Api-Key: $JULES_API_KEY" 2>/dev/null)
state=$(printf "%s" "$raw" | jq -r '.state // "UNKNOWN"')

case "$state" in
	FAILED)
		echo "nudge.sh: session $SID is FAILED — relaunch, do not nudge" >&2
		exit 1
		;;
	COMPLETED)
		pr=$(printf "%s" "$raw" | jq -r '.outputs // [] | map(select(.pullRequest)) | .[0].pullRequest.url // ""')
		if [[ -z "$pr" || "$pr" == "null" ]]; then
			echo "nudge.sh: session $SID is COMPLETED without PR — relaunch, do not nudge" >&2
			exit 1
		else
			echo "nudge.sh: session $SID is COMPLETED with PR $pr; nudge is a no-op" >&2
			exit 1
		fi
		;;
	IN_PROGRESS|AWAITING_USER_FEEDBACK|AWAITING_PLAN_APPROVAL)
		# ok to nudge; AWAITING_PLAN_APPROVAL is auto-rejected in practice
		;;
	*)
		echo "nudge.sh: session $SID is in unexpected state '$state'; aborting" >&2
		exit 1
		;;
esac

# --- send ------------------------------------------------------------------

"$JULES_BIN" send --session "$SID" --prompt "$MSG"
echo "  → nudged $SID with: $MSG"
