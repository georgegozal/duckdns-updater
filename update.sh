#!/bin/sh
# Keep DuckDNS pointed at this host's current public IP.
#
# Why this is a container and not three lines in a compose file: the three-line
# version cannot fail. It echoes "KO", sleeps, and the container stays happily
# "running" forever. On a residential connection the thing that depends on this
# — a Let's Encrypt renewal — happens about every 60 days, so a silent failure
# is discovered by the certificate expiring, months after the cause.
#
# So this script's real job is not curl. It is: know whether the last update
# actually worked, and make that visible to `docker ps`.
set -eu

: "${DUCKDNS_DOMAINS:?set DUCKDNS_DOMAINS (comma-separated, without .duckdns.org)}"
INTERVAL="${INTERVAL:-300}"
STATE_DIR="${STATE_DIR:-/var/lib/duckdns}"
STATE_FILE="$STATE_DIR/last-success"
RETRIES="${RETRIES:-3}"

# The token may come from a file instead of the environment. Both are visible in
# `docker inspect`, but a file can be a Docker/Swarm secret or a mount with
# tight permissions, which an environment variable cannot.
if [ -n "${DUCKDNS_TOKEN_FILE:-}" ]; then
    [ -r "$DUCKDNS_TOKEN_FILE" ] || { echo "cannot read $DUCKDNS_TOKEN_FILE" >&2; exit 1; }
    DUCKDNS_TOKEN=$(tr -d '[:space:]' < "$DUCKDNS_TOKEN_FILE")
fi
: "${DUCKDNS_TOKEN:?set DUCKDNS_TOKEN or DUCKDNS_TOKEN_FILE}"
# .strip() equivalent: a token pasted into an .env file or a secret often keeps
# a trailing newline, and DuckDNS answers a plain "KO" to a malformed token with
# no hint about why.
DUCKDNS_TOKEN=$(printf '%s' "$DUCKDNS_TOKEN" | tr -d '[:space:]')

mkdir -p "$STATE_DIR"

log() { echo "$(date -Iseconds) $*"; }

update() {
    # ip= empty asks DuckDNS to use the source address it sees, which is the
    # whole point on a dynamic connection — nothing here has to discover the
    # public IP, and no third-party "what is my IP" service is involved.
    #
    # The URL carries the token, so it is NEVER logged and curl is never run
    # verbosely. Only the response body is printed.
    url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAINS}&token=${DUCKDNS_TOKEN}&ip="
    [ -n "${DUCKDNS_IPV6:-}" ] && url="${url}&ipv6=${DUCKDNS_IPV6}"

    # --fail is deliberately NOT used. DuckDNS answers HTTP 200 for both success
    # and failure, distinguishing them only by a body of "OK" or "KO", so the
    # exit code says nothing about whether the record changed. This is the bug
    # most inline one-liners have.
    body=$(curl -sS --max-time 30 "${DUCKDNS_ENDPOINT:-$url}" 2>/dev/null) || return 1
    case "$body" in
        OK*) return 0 ;;
        KO*) log "duckdns refused the update (KO) — check the token and that every"\
                 "domain in DUCKDNS_DOMAINS belongs to it"; return 2 ;;
        *)   log "unexpected response from duckdns: ${body:-<empty>}"; return 3 ;;
    esac
}

log "updating ${DUCKDNS_DOMAINS} every ${INTERVAL}s"

while :; do
    attempt=1
    while :; do
        # The status is captured DIRECTLY, not read back after an `if`. A failed
        # `if cmd; then ...; fi` with no else branch leaves `$?` at 0 — the `if`
        # statement itself succeeded — so reading `$?` afterwards always gave 0
        # and the KO case below could never be recognised. Every KO was retried
        # as though it were a network blip.
        update && status=0 || status=$?
        if [ "$status" -eq 0 ]; then
            date -Iseconds > "$STATE_FILE"
            log "ok"
            break
        fi
        # A KO is a configuration error and retrying cannot fix it; a network
        # failure is transient and worth a short backoff rather than waiting a
        # whole interval to try again.
        if [ "$status" -eq 2 ] || [ "$attempt" -ge "$RETRIES" ]; then
            log "giving up for this round after ${attempt} attempt(s)"
            break
        fi
        backoff=$((attempt * 5))
        log "retrying in ${backoff}s"
        sleep "$backoff"
        attempt=$((attempt + 1))
    done
    sleep "$INTERVAL"
done
