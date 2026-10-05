#!/usr/bin/env bash
#
# Keep one comment on the pull request up to date with where its preview is.
#
# The comment is found again by a marker on its first line, so a pull request
# gets one comment that changes, not one per push. Best-effort throughout: a
# fork's workflow token cannot comment, and that is no reason to fail a deploy
# that already happened.
set -euo pipefail

MARKER='<!-- vela-preview -->'

[ -n "${VELA_PR_NUMBER:-}" ] || exit 0
[ "${VELA_OUTCOME:-skipped}" != skipped ] || exit 0
# A preview skipped because its pull request closed: the cleanup run has the
# last word on the comment, and "deploy failed" would be wrong.
[ "${VELA_MODE:-}" != skipped ] || exit 0
if ! command -v gh >/dev/null 2>&1; then
	echo "::notice::gh is not available on this runner, so the preview comment was not posted"
	exit 0
fi

case "${VELA_MODE:-}:${VELA_OUTCOME:-}" in
	destroy:success)
		body=$(printf '%s\n**Preview removed.** `%s` is no longer deployed.' "$MARKER" "${VELA_TARGET:-preview}")
		;;
	deploy:success)
		hosts=""
		if [ -n "${VELA_HOSTNAMES:-}" ]; then
			hosts=$(printf '%s' "$VELA_HOSTNAMES" | tr ',' '\n' | sed 's|^|- https://|' | paste -sd '\n' -)
		fi
		body=$(printf '%s\n**Preview deployed** to %s\n\n%s\n\nRelease `%s`.' \
			"$MARKER" "${VELA_URL:-the server}" "$hosts" "${VELA_RELEASE:-unknown}")
		;;
	*)
		body=$(printf '%s\n**Preview %s failed.** See the [workflow run](%s).' \
			"$MARKER" "${VELA_MODE:-deploy}" "${VELA_RUN_URL:-}")
		;;
esac

existing=$(gh api "repos/$GH_REPO/issues/$VELA_PR_NUMBER/comments" --paginate \
	--jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" 2>/dev/null | head -n1 || true)

if [ -n "$existing" ]; then
	gh api -X PATCH "repos/$GH_REPO/issues/comments/$existing" -f body="$body" >/dev/null \
		|| echo "::warning::could not update the preview comment"
else
	gh api -X POST "repos/$GH_REPO/issues/$VELA_PR_NUMBER/comments" -f body="$body" >/dev/null \
		|| echo "::warning::could not post the preview comment"
fi
