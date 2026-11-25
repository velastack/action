#!/usr/bin/env bash
#
# Run `vela deploy` against the configured server, then publish what landed as
# step outputs.
#
# The CLI comes from the project's own devDependencies unless a version is
# pinned on the action, so CI deploys with exactly the vela the project builds
# with locally.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Checked again here although the first step did: with a `server` input that
# step has no reason to open the file, and this is the step that would mint.
require_project_identity || exit 1

if [ -n "${VELA_CLI_VERSION:-}" ]; then
	# A bare version means npm; anything with a slash or scheme (github:owner/repo,
	# a git URL, a tarball) is passed to npx as written.
	case "$VELA_CLI_VERSION" in
		*[:/]*) VELA=(npx --yes "$VELA_CLI_VERSION") ;;
		*) VELA=(npx --yes "vela@${VELA_CLI_VERSION}") ;;
	esac
	# Asking for a version explicitly means running that version. Without this the
	# CLI would hand the command straight back to whatever the project pins.
	export VELA_NO_DELEGATE=1
elif [ -x node_modules/.bin/vela ]; then
	VELA=(node_modules/.bin/vela)
else
	VELA=(npx --yes vela)
fi

# Which copy of the app: the `target` input, else a preview of the pull
# request's branch, else production. Resolved by the first step, which needed
# it to find the server; worked out here only when that step did not run.
is_pull_request=0
case "${VELA_EVENT_NAME:-}" in pull_request*) is_pull_request=1 ;; esac

TARGET=${VELA_RESOLVED_TARGET:-}
if [ -z "$TARGET" ]; then TARGET=$(resolve_target); fi

is_preview=0
case "$TARGET" in preview:*) is_preview=1 ;; esac

# Deploy, or take a preview down: `auto` removes the preview when its pull
# request closes and deploys on every other event. It only ever removes a
# preview. Anything else that reaches a `closed` event with `auto` - a
# workflow that sets `target: staging` and includes `closed` in its trigger,
# say - is a mistake, and the action refuses rather than guess.
MODE=${VELA_ACTION:-auto}
if [ "$MODE" = auto ]; then
	if [ "$is_pull_request" = 1 ] && [ "${VELA_EVENT_ACTION:-}" = closed ]; then
		if [ "$is_preview" != 1 ]; then
			echo "::error title=Refusing to remove $TARGET::action: auto only removes previews, and \`$TARGET\` is not one. Set action: deploy, or skip this job on closed pull requests."
			exit 1
		fi
		MODE=destroy
	else
		MODE=deploy
	fi
fi

# Exit status vela uses when the target was removed after the deploy began
# (TARGET_REMOVED_EXIT in the CLI). Older CLIs never exit with it.
VELA_TARGET_REMOVED=3

# Nothing deployed, on purpose: the target is gone, or its pull request has
# closed. Reported as its own outcome, so neither the run nor the pull request
# comment calls it a failure.
skip() {
	echo "::notice title=Not deployed::$1"
	{
		echo "mode=skipped"
		echo "target=$TARGET"
		echo "release="
		echo "url="
		echo "hostnames="
	} >> "$GITHUB_OUTPUT"
	echo "### Skipped \`$TARGET\`: $1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
	exit 0
}

# A push to a pull request that closes while this run is still building or
# testing is a preview nobody will look at - and since the closed event's
# cleanup has already run (it skips the checks, so it overtakes this run), one
# that nothing would ever remove. Checked here, before minutes of building; the
# CLI repeats the check on the server, where it also covers a close that lands
# mid-build. Best-effort: without a usable token this just deploys.
if [ "$MODE" = deploy ] && [ "$is_preview" = 1 ] && [ "$is_pull_request" = 1 ] \
	&& [ -n "${VELA_PR_NUMBER:-}" ] && command -v gh >/dev/null 2>&1; then
	if pr_state=$(gh api "repos/$GH_REPO/pulls/$VELA_PR_NUMBER" --jq .state 2>/dev/null); then
		if [ "$pr_state" = closed ]; then
			skip "pull request #$VELA_PR_NUMBER closed while this run was in progress, so its preview was not deployed"
		fi
	else
		echo "::warning::could not read the state of pull request #$VELA_PR_NUMBER; deploying the preview anyway"
	fi
fi

ssh_args=(--server "$VELA_SERVER" --identity "$VELA_IDENTITY" --accept-host-keys)
if [ -n "${VELA_SSH_PORT:-}" ]; then ssh_args+=(--ssh-port "$VELA_SSH_PORT"); fi

if [ "$MODE" = destroy ]; then
	destroy_args=(destroy deployment -t "$TARGET" "${ssh_args[@]}" --yes)
	if [ "$is_preview" = 1 ]; then
		# A preview is disposable by definition, and one that keeps its database
		# keeps its port pair and disk with it. The CLI snapshots the data into
		# the server's trash before purging.
		destroy_args+=(--purge)
	else
		# Removing production or a named environment from CI needs the app name
		# typed into the workflow, the same way the CLI asks for it on a terminal.
		# `--yes` on its own is not enough for that, and older CLIs (which still
		# accept it) are refused rather than trusted.
		if [ -z "${VELA_CONFIRM_NAME:-}" ]; then
			echo "::error title=Refusing to remove $TARGET::removing a target other than a preview needs the confirm-name input set to the app's name"
			exit 1
		fi
		if ! "${VELA[@]}" destroy deployment --help 2>/dev/null | grep -q -- '--confirm'; then
			echo "::error title=Refusing to remove $TARGET::this version of vela cannot confirm a destroy by name; upgrade the project's vela devDependency"
			exit 1
		fi
		destroy_args+=(--confirm "$VELA_CONFIRM_NAME")
	fi

	echo "::group::vela destroy deployment -t $TARGET --server $VELA_SERVER"
	"${VELA[@]}" "${destroy_args[@]}"
	echo "::endgroup::"

	{
		echo "mode=destroy"
		echo "target=$TARGET"
		echo "release="
		echo "url="
		echo "hostnames="
	} >> "$GITHUB_OUTPUT"

	{
		echo "### Removed \`$TARGET\` from \`$VELA_SERVER\`"
	} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
	exit 0
fi

args=(deploy -t "$TARGET" "${ssh_args[@]}")

if [ -n "${VELA_DOMAIN:-}" ]; then args+=(--domain "$VELA_DOMAIN"); fi
if [ -n "${VELA_PROJECT:-}" ]; then args+=(--project "$VELA_PROJECT"); fi
if [ -n "${VELA_HEALTH_PATH:-}" ]; then args+=(--health-path "$VELA_HEALTH_PATH"); fi
# Three states, not two: passing neither flag is what lets the CLI apply its own
# default, which is to build against the deployed database once there is one.
# Forcing a value here would make every CI deploy opt out of that silently.
case "${VELA_REMOTE_DB:-}" in
	true) args+=(--remote-db) ;;
	false) args+=(--no-remote-db) ;;
esac

echo "::group::vela deploy -t $TARGET --server $VELA_SERVER"
rc=0
"${VELA[@]}" "${args[@]}" || rc=$?
echo "::endgroup::"
if [ "$rc" = "$VELA_TARGET_REMOVED" ]; then
	skip "\`$TARGET\` was removed from the server while this deploy was building, so it was not put back"
fi
if [ "$rc" != 0 ]; then exit "$rc"; fi

# Report the result from the server rather than by scraping the deploy output.
# Not error-suppressed: a status call that breaks would otherwise emit an empty
# release and a summary reading "unknown", which looks like a successful deploy.
status=$("${VELA[@]}" status -t "$TARGET" "${ssh_args[@]}" --json)

release=$(printf '%s' "$status" | jq -r '.[0].activeRelease // ""')
domain=$(printf '%s' "$status" | jq -r '.[0].domain // ""')
managed=$(printf '%s' "$status" | jq -r '.[0].managed // ""')
url=$(printf '%s' "$status" | jq -r '.[0].url // ""')
# A domain the user's DNS points at the server, then the managed
# velastack.app name; the first is what the app is served as.
hostnames=$(printf '%s,%s' "$domain" "$managed" | tr ',' '\n' | sed '/^$/d' | paste -sd, -)
case "$url" in
	https://*) ;;
	*) url=""; if [ -n "$hostnames" ]; then url="https://${hostnames%%,*}"; fi ;;
esac

{
	echo "mode=deploy"
	echo "target=$TARGET"
	echo "release=$release"
	echo "url=$url"
	echo "hostnames=$hostnames"
} >> "$GITHUB_OUTPUT"

{
	echo "### Deployed to \`$VELA_SERVER\`"
	echo
	echo "| | |"
	echo "|---|---|"
	echo "| Target | \`$TARGET\` |"
	echo "| Release | \`${release:-unknown}\` |"
	if [ -n "$url" ]; then echo "| URL | $url |"; fi
	if [ -n "$hostnames" ]; then echo "| Hostnames | \`$hostnames\` |"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
