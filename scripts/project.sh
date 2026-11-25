#!/usr/bin/env bash
#
# Read what the repository already says about this deploy, before anything is
# installed: which server the target runs on.
#
# That used to be the workflow's job (a `server` input), although the deploy
# that created the target records it in the committed .vela/project.json.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${VELA_WORKING_DIRECTORY:-.}"

TARGET=$(resolve_target)

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

{
	echo "target=$TARGET"
	echo "server=$SERVER"
} >> "$GITHUB_OUTPUT"
