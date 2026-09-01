#!/usr/bin/env bash
#
# Run `vela deploy` against the configured server, then publish what landed as
# step outputs.
#
# The CLI comes from the project's own devDependencies unless a version is
# pinned on the action, so CI deploys with exactly the vela the project builds
# with locally.
set -euo pipefail

# CI must never mint a project identity. `vela` writes a fresh app id into
# .vela/project.json whenever it finds none, and a runner's copy of the
# repository is thrown away at the end of the job - so every deploy would land
# as a brand new app and leave the previous one orphaned on the server, with its
# own database, ports and systemd units.
#
# The file is created by the first `vela deploy` (or `vela link`) run locally,
# and belongs in version control.
PROJECT_FILE=.vela/project.json
if [ ! -f "$PROJECT_FILE" ] || [ -z "$(jq -r '.appId // .projectId // ""' "$PROJECT_FILE" 2>/dev/null)" ]; then
	echo "::error title=No vela project id::$PROJECT_FILE is missing or has no app id"
	cat >&2 <<-'MSG'

		This project has no committed vela identity, so deploying from CI would
		create a new app on every run.

		Set it up once from a checkout on your own machine:

		  vela deploy --server <user@server> --domain <your-domain>
		  git add .vela/project.json && git commit -m "Add the vela project id"

		Then re-run this workflow.

	MSG
	exit 1
fi

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

# `target` is the input; `environment` is what it used to be called and still
# works, so a workflow written against the old action keeps deploying.
TARGET=${VELA_TARGET:-${VELA_ENVIRONMENT:-production}}

args=(
	deploy
	-t "$TARGET"
	--server "$VELA_SERVER"
	--identity "$VELA_IDENTITY"
	--accept-host-keys
)

if [ -n "${VELA_DOMAIN:-}" ]; then args+=(--domain "$VELA_DOMAIN"); fi
if [ -n "${VELA_PROJECT:-}" ]; then args+=(--project "$VELA_PROJECT"); fi
if [ -n "${VELA_HEALTH_PATH:-}" ]; then args+=(--health-path "$VELA_HEALTH_PATH"); fi
if [ -n "${VELA_SSH_PORT:-}" ]; then args+=(--ssh-port "$VELA_SSH_PORT"); fi
# Three states, not two: passing neither flag is what lets the CLI apply its own
# default, which is to build against the deployed database once there is one.
# Forcing a value here would make every CI deploy opt out of that silently.
case "${VELA_REMOTE_DB:-}" in
	true) args+=(--remote-db) ;;
	false) args+=(--no-remote-db) ;;
esac

echo "::group::vela deploy -t $TARGET --server $VELA_SERVER"
"${VELA[@]}" "${args[@]}"
echo "::endgroup::"

# Report the result from the server rather than by scraping the deploy output.
# Not error-suppressed: a status call that breaks would otherwise emit an empty
# release and a summary reading "unknown", which looks like a successful deploy.
status=$("${VELA[@]}" status -t "$TARGET" --server "$VELA_SERVER" \
	--identity "$VELA_IDENTITY" --accept-host-keys --json)

release=$(printf '%s' "$status" | jq -r '.[0].activeRelease // ""')
domain=$(printf '%s' "$status" | jq -r '.[0].domain // ""')
url=""
if [ -n "$domain" ]; then url="https://${domain%%,*}"; fi

{
	echo "release=$release"
	echo "url=$url"
} >> "$GITHUB_OUTPUT"

{
	echo "### Deployed to \`$VELA_SERVER\`"
	echo
	echo "| | |"
	echo "|---|---|"
	echo "| Target | \`$TARGET\` |"
	echo "| Release | \`${release:-unknown}\` |"
	if [ -n "$url" ]; then echo "| URL | $url |"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
