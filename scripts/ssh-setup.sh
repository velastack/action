#!/usr/bin/env bash
#
# Put the deploy key and the server's host key where OpenSSH will find them.
#
# The key is written to a file rather than passed around in an argument, and the
# path is exported so the deploy step can point `vela` at it and delete it
# afterwards.
set -euo pipefail

[ -n "${VELA_SSH_KEY:-}" ] || {
	echo "::error::The ssh-key input is empty. Add your deploy key as a repository secret and pass it to the action."
	exit 1
}
[ -n "${VELA_SERVER:-}" ] || {
	echo "::error::The server input is required."
	exit 1
}

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

IDENTITY="$SSH_DIR/vela_deploy_key"
# printf adds the trailing newline OpenSSH insists on; a key that ends mid-line
# is the most common cause of "invalid format".
printf '%s\n' "$VELA_SSH_KEY" > "$IDENTITY"
chmod 600 "$IDENTITY"

if ! ssh-keygen -y -f "$IDENTITY" >/dev/null 2>&1; then
	echo "::error::The ssh-key input is not a usable private key. Pass the whole file, including the BEGIN and END lines."
	exit 1
fi

# The target may be `user@host`; the host key is keyed on the host alone.
HOST=${VELA_SERVER##*@}
PORT=${VELA_SSH_PORT:-22}

KNOWN_HOSTS="$SSH_DIR/known_hosts"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

if [ -n "${VELA_KNOWN_HOSTS:-}" ]; then
	printf '%s\n' "$VELA_KNOWN_HOSTS" >> "$KNOWN_HOSTS"
else
	echo "Fetching the host key for $HOST — pin it with the known-hosts input to guard against a changed server."
	ssh-keyscan -p "$PORT" -H "$HOST" >> "$KNOWN_HOSTS" 2>/dev/null || {
		echo "::error::Could not reach $HOST:$PORT to fetch its host key."
		exit 1
	}
fi

echo "identity=$IDENTITY" >> "$GITHUB_OUTPUT"
