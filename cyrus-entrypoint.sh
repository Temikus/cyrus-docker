#!/bin/sh
set -eu

mkdir -p "$HOME/.cyrus"

# With Linear creds set and no repos, Cyrus starts in idle mode, which never
# writes config.json; `cyrus self-auth-linear` then refuses to run.
[ -f "$HOME/.cyrus/config.json" ] || printf '{"repositories": []}\n' > "$HOME/.cyrus/config.json"

# Cyrus reads the GitHub App key only from $CYRUS_HOME/github-app.pem.
if [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  (umask 077 && printf '%s\n' "$GITHUB_APP_PRIVATE_KEY" > "$HOME/.cyrus/github-app.pem")
fi

exec "$@"
