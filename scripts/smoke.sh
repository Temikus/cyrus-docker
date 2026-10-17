#!/usr/bin/env bash
# Boot the built image and assert it serves on all interfaces, runs
# unprivileged, and has the agent toolchain. Real container, real HTTP.
#
# Usage: scripts/smoke.sh <image> [expected-cyrus-version]
set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image> [version]}"
WANT_VERSION="${2:-}"
PORT="${SMOKE_PORT:-13456}"
NAME="cyrus-smoke-$$"
VOLUME="cyrus-smoke-$$"
# Not a real key: the test only checks the entrypoint copies it verbatim.
PEM=$'-----BEGIN TEST KEY-----\nsmoke\n-----END TEST KEY-----'

failures=0

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check() {
    local what="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then
        printf 'ok   %-34s %s\n' "${what}" "${got}"
    else
        printf 'FAIL %-34s want %q, got %q\n' "${what}" "${want}" "${got}"
        failures=$((failures + 1))
    fi
}

echo "== booting ${IMAGE} =="
docker run -d --name "${NAME}" \
    -p "127.0.0.1:${PORT}:3456" \
    -v "${VOLUME}:/home/node" \
    -e CYRUS_SENTRY_DISABLED=1 \
    -e GITHUB_APP_PRIVATE_KEY="${PEM}" \
    "${IMAGE}" >/dev/null

# Cyrus logs this once the HTTP server is accepting connections.
for _ in $(seq 1 60); do
    if docker logs "${NAME}" 2>&1 | grep -q 'Shared application server listening'; then
        break
    fi
    if [ -z "$(docker ps -q -f "name=${NAME}")" ]; then
        echo "FAIL container exited during startup:"
        docker logs "${NAME}" 2>&1 | tail -20
        exit 1
    fi
    sleep 1
done

echo
echo "== identity =="
check "uid" "1000" "$(docker exec "${NAME}" id -u)"
check "username" "node" "$(docker exec "${NAME}" id -un)"
check "PID 1" "tini" "$(docker exec "${NAME}" cat /proc/1/comm)"

echo
echo "== tools on PATH =="
for bin in cyrus claude gh git jq bwrap socat; do
    # socat has no --version; -V prints the version and exits 0.
    flag="--version"
    [ "${bin}" = socat ] && flag="-V"
    # Capture first, then trim: piping into head would hide a failing exit code.
    if version="$(docker exec "${NAME}" "${bin}" "${flag}" 2>&1)"; then
        printf 'ok   %-34s %s\n' "${bin}" "${version%%$'\n'*}"
    else
        printf 'FAIL %-34s --version failed: %s\n' "${bin}" "${version%%$'\n'*}"
        failures=$((failures + 1))
    fi
done
if [ -n "${WANT_VERSION}" ]; then
    check "cyrus version" "${WANT_VERSION}" "$(docker exec "${NAME}" cyrus --version)"
fi

echo
echo "== http =="
# Without CYRUS_HOST_EXTERNAL the server binds localhost and this would fail
# to connect. 401 means it is reachable and rejecting the unsigned request.
check "unsigned POST /linear-webhook" "401" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/linear-webhook" || echo failed)"
# No GITHUB_WEBHOOK_SECRET or CYRUS_API_KEY here, so the route expects a
# Bearer token equal to the empty string. Nothing may get through.
for auth in "" "Authorization: Bearer "; do
    check "POST /github-webhook [${auth:-no auth}]" "401" \
        "$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
            -H 'content-type: application/json' -H 'x-github-event: issue_comment' \
            ${auth:+-H "${auth}"} -d '{"action":"created"}' \
            "http://127.0.0.1:${PORT}/github-webhook" || echo failed)"
done

echo
echo "== entrypoint =="
check "config.json seeded" '{"repositories": []}' \
    "$(docker exec "${NAME}" cat /home/node/.cyrus/config.json)"
check "github-app.pem contents" "${PEM}" \
    "$(docker exec "${NAME}" cat /home/node/.cyrus/github-app.pem)"
check "github-app.pem mode" "600" \
    "$(docker exec "${NAME}" stat -c '%a' /home/node/.cyrus/github-app.pem)"

echo
echo "== linear self-auth on a second port =="
# The running server holds 3456, so the README runs self-auth on 3457.
auth_output="$(docker exec \
    -e LINEAR_CLIENT_ID=smoke-client-id-0000000000 \
    -e LINEAR_CLIENT_SECRET=smoke \
    -e CYRUS_BASE_URL=http://localhost:3457 \
    -e CYRUS_SERVER_PORT=3457 \
    "${NAME}" timeout 10 cyrus self-auth-linear 2>&1 || true)"
case "${auth_output}" in
    *"Waiting for authorization on port 3457"*)
        printf 'ok   %-34s %s\n' "self-auth-linear" "waiting for callback" ;;
    *)
        printf 'FAIL %-34s got %q\n' "self-auth-linear" "${auth_output}"
        failures=$((failures + 1)) ;;
esac

echo
if [ "${failures}" -ne 0 ]; then
    echo "${failures} check(s) failed"
    docker logs "${NAME}" 2>&1 | tail -20
    exit 1
fi
echo "all checks passed"
