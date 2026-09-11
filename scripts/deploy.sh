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

		  vela link
		  vela deploy --server <user@server> --domain <your-domain>
		  git add .vela/project.json && git commit -m "Add the vela project id"

		Then re-run this workflow. (`vela link` is what previews and the
		velastack.dev dashboard need; a plain deploy works without it.)

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

# Which copy of the app. `target` is the input; `environment` is what it used
# to be called and still works. Given neither, the event decides: a pull
# request gets a preview of its branch, anything else is production.
is_pull_request=0
case "${VELA_EVENT_NAME:-}" in pull_request*) is_pull_request=1 ;; esac

if [ -n "${VELA_TARGET:-}" ]; then
	TARGET=$VELA_TARGET
elif [ -n "${VELA_ENVIRONMENT:-}" ]; then
	TARGET=$VELA_ENVIRONMENT
elif [ "$is_pull_request" = 1 ]; then
	# A pull request with no branch name is not a thing that should happen, and
	# the one target it must never quietly become is production: on a `closed`
	# event that would remove the live site.
	if [ -z "${VELA_HEAD_REF:-}" ]; then
		echo "::error title=No branch for the preview::the pull request event carries no head ref, so there is no preview to name"
		exit 1
	fi
	TARGET="preview:$VELA_HEAD_REF"
else
	TARGET=production
fi

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
"${VELA[@]}" "${args[@]}"
echo "::endgroup::"

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
