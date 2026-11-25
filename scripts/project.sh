#!/usr/bin/env bash
#
# Read what the repository already says about this deploy, before anything is
# installed: which server the target runs on, and which package manager the
# project pins its dependencies with.
#
# Both used to be the workflow's job (a `server` input, and an npm lockfile
# or nothing). The first is recorded in the committed .vela/project.json by
# the deploy that created the target; the second is the lockfile that is there.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${VELA_WORKING_DIRECTORY:-.}"

TARGET=$(resolve_target)

# --- server -----------------------------------------------------------------

SERVER=${VELA_SERVER:-}
if [ -z "$SERVER" ]; then
	# With no `server` input the binding is the only source, and the binding
	# lives in the same file as the app id.
	require_project_identity || exit 1
	SERVER=$(target_server "$TARGET")
	if [ -z "$SERVER" ]; then
		echo "::error title=No server for $TARGET::the server input is not set, and $PROJECT_FILE records no server for \`$TARGET\`"
		cat >&2 <<-MSG

			The action reads the server from $PROJECT_FILE, where the first deploy of
			a target records it. \`$TARGET\` has no entry there.

			Deploy it once from your own machine and commit the file:

			  vela deploy -t $TARGET --server <user@server>
			  git add $PROJECT_FILE && git commit -m "Record the $TARGET server"

			or pass the server to the action: \`server: user@your-server\`.

		MSG
		exit 1
	fi
	echo "Deploying \`$TARGET\` to $SERVER (from $PROJECT_FILE)"
fi

# --- package manager --------------------------------------------------------

# The lockfile decides. With both, npm: the CLI makes the same choice, and the
# server installs with npm either way.
MANAGER=none
PNPM_VERSION=
if [ -f package-lock.json ]; then
	MANAGER=npm
elif [ -f pnpm-lock.yaml ]; then
	MANAGER=pnpm
	# The exact version the project pins, when it pins one...
	pinned=$(jq -r '.packageManager // "" | strings' package.json 2>/dev/null || true)
	case "$pinned" in
		pnpm@*)
			PNPM_VERSION=${pinned#pnpm@}
			# `pnpm@10.4.1+sha512.…`: the hash is corepack's, not part of the version.
			PNPM_VERSION=${PNPM_VERSION%%+*}
			;;
	esac
	# ...otherwise the newest major that reads the lockfile as written, since
	# `--frozen-lockfile` refuses one it would have to convert.
	if [ -z "$PNPM_VERSION" ]; then
		lock=$(sed -n "s/^lockfileVersion: *['\"]\{0,1\}\([0-9][0-9.]*\).*/\1/p" pnpm-lock.yaml | head -1)
		case "$lock" in
			9 | 9.*) PNPM_VERSION=10 ;;
			6 | 6.*) PNPM_VERSION=8 ;;
			5 | 5.*) PNPM_VERSION=7 ;;
			*) PNPM_VERSION=latest ;;
		esac
	fi
elif [ "${VELA_INSTALL:-true}" = true ]; then
	other=
	for file in yarn.lock bun.lock bun.lockb; do
		if [ -f "$file" ]; then
			other=$file
			break
		fi
	done
	if [ -n "$other" ]; then
		echo "::error title=Unsupported lockfile::found $other, and the action installs with npm or pnpm only"
		cat >&2 <<-MSG

			This action installs dependencies from a package-lock.json (npm ci) or a
			pnpm-lock.yaml (pnpm install --frozen-lockfile). The project has $other.

			Commit one of those two lockfiles, or install the dependencies in an
			earlier step of the workflow and set \`install: false\`.

		MSG
	else
		echo "::error title=No lockfile::the action needs a package-lock.json or a pnpm-lock.yaml to install from"
		cat >&2 <<-'MSG'

			Neither package-lock.json nor pnpm-lock.yaml is committed, so there is
			nothing reproducible to install. Run `npm install` (or `pnpm install`)
			locally and commit the lockfile it writes, or install the dependencies in
			an earlier step of the workflow and set `install: false`.

		MSG
	fi
	exit 1
fi

echo "Package manager: $MANAGER${PNPM_VERSION:+ (pnpm@$PNPM_VERSION)}"

{
	echo "target=$TARGET"
	echo "server=$SERVER"
	echo "manager=$MANAGER"
	echo "pnpm-version=$PNPM_VERSION"
} >> "$GITHUB_OUTPUT"
