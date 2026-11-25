#!/usr/bin/env bash
#
# Shared by the steps that have to agree on two things before anything is
# built: which target this run is about, and which project it belongs to.
# Sourced, never run.

PROJECT_FILE=.vela/project.json

# CI must never mint a project identity. `vela` writes a fresh app id into
# .vela/project.json whenever it finds none, and a runner's copy of the
# repository is thrown away at the end of the job - so every deploy would land
# as a brand new app and leave the previous one orphaned on the server, with its
# own database, ports and systemd units.
#
# The file is created by the first `vela deploy` (or `vela link`) run locally,
# and belongs in version control.
require_project_identity() {
	if [ -f "$PROJECT_FILE" ] && [ -n "$(jq -r '.appId // .projectId // ""' "$PROJECT_FILE" 2>/dev/null)" ]; then
		return 0
	fi
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
	return 1
}

# Which copy of the app. `target` is the input; `environment` is what it used
# to be called and still works. Given neither, the event decides: a pull
# request gets a preview of its branch, anything else is production.
#
# Prints the target. Fails, having said why, when there is none to name.
resolve_target() {
	if [ -n "${VELA_TARGET:-}" ]; then
		printf '%s' "$VELA_TARGET"
		return 0
	fi
	if [ -n "${VELA_ENVIRONMENT:-}" ]; then
		printf '%s' "$VELA_ENVIRONMENT"
		return 0
	fi
	case "${VELA_EVENT_NAME:-}" in
		pull_request*)
			# A pull request with no branch name is not a thing that should happen,
			# and the one target it must never quietly become is production: on a
			# `closed` event that would remove the live site.
			if [ -z "${VELA_HEAD_REF:-}" ]; then
				echo "::error title=No branch for the preview::the pull request event carries no head ref, so there is no preview to name" >&2
				return 1
			fi
			printf 'preview:%s' "$VELA_HEAD_REF"
			;;
		*) printf 'production' ;;
	esac
}

# The server one key of .vela/project.json is bound to, or nothing. Reads the
# current shape (`targets.<key>.server`) and the one before targets were named
# (`deployments.<key>.target`), as the CLI does.
binding_server() {
	[ -f "$PROJECT_FILE" ] || return 0
	jq -r --arg key "$1" \
		'(.targets[$key].server // .deployments[$key].target // "") | strings' \
		"$PROJECT_FILE" 2>/dev/null || true
}

# The server a target runs on, from the bindings `vela deploy` recorded.
#
# The keys are the CLI's env tags, not the names people type: production is
# stored as `prod` (the two are the same target), every preview shares the one
# `preview` binding, and anything else is its own lowercased name. A preview
# with no binding of its own goes where production is, which is where the CLI
# would be told to put it by a workflow that passed `server` for both.
target_server() {
	local target key server
	target=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case "$target" in
		production | prod) key=prod ;;
		preview | preview:*) key=preview ;;
		*) key=$target ;;
	esac
	server=$(binding_server "$key")
	if [ -z "$server" ] && [ "$key" = preview ]; then
		server=$(binding_server prod)
	fi
	printf '%s' "$server"
}
