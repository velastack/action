#!/usr/bin/env bash
#
# Work out which Node.js the project builds with.
#
# The explicit input wins; otherwise the repository says so itself through
# .nvmrc or .node-version, which is what a developer's own shell reads. Falling
# back to a version the project did not ask for is how a build ends up failing
# on an engine constraint that never bites locally.
set -euo pipefail

DIR=${VELA_WORKING_DIRECTORY:-.}

resolve() {
	if [ -n "${VELA_NODE_VERSION:-}" ]; then
		printf '%s' "$VELA_NODE_VERSION"
		return
	fi
	for file in "$DIR/.nvmrc" "$DIR/.node-version" .nvmrc .node-version; do
		if [ -f "$file" ]; then
			local value
			value=$(tr -d ' \t\r' < "$file" | grep -v '^$' | head -1)
			if [ -n "$value" ]; then
				printf '%s' "$value"
				return
			fi
		fi
	done
	printf '22'
}

VERSION=$(resolve)
echo "Building with Node.js $VERSION"
echo "version=$VERSION" >> "$GITHUB_OUTPUT"
