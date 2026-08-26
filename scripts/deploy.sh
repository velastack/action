#!/usr/bin/env bash
#
# Run `vela deploy` against the configured server, then publish what landed as
# step outputs.
#
# The CLI comes from the project's own devDependencies unless a version is
# pinned on the action, so CI deploys with exactly the vela the project builds
# with locally.
set -euo pipefail

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

ENVIRONMENT=${VELA_ENVIRONMENT:-prod}

args=(
	deploy "$VELA_SERVER"
	--env "$ENVIRONMENT"
	--identity "$VELA_IDENTITY"
	--accept-host-keys
)

if [ -n "${VELA_DOMAIN:-}" ]; then args+=(--domain "$VELA_DOMAIN"); fi
if [ -n "${VELA_PROJECT:-}" ]; then args+=(--project "$VELA_PROJECT"); fi
if [ -n "${VELA_HEALTH_PATH:-}" ]; then args+=(--health-path "$VELA_HEALTH_PATH"); fi
if [ -n "${VELA_SSH_PORT:-}" ]; then args+=(--ssh-port "$VELA_SSH_PORT"); fi

echo "::group::vela deploy $VELA_SERVER --env $ENVIRONMENT"
"${VELA[@]}" "${args[@]}"
echo "::endgroup::"

# Report the result from the server rather than by scraping the deploy output.
status=$("${VELA[@]}" status "$VELA_SERVER" \
	--env "$ENVIRONMENT" --identity "$VELA_IDENTITY" --accept-host-keys --json 2>/dev/null || echo '[]')

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
	echo "| Environment | \`$ENVIRONMENT\` |"
	echo "| Release | \`${release:-unknown}\` |"
	if [ -n "$url" ]; then echo "| URL | $url |"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
