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

# ── one request PER DOMAIN, deliberately ────────────────────────────────────
#
# DuckDNS accepts a comma-separated list in a single request, and sending one
# is what this script did. But it answers **KO for the whole batch** if any one
# domain does not belong to the token — so a single domain you stopped caring
# about, or deleted at DuckDNS, silently stopped the other four from updating
# at all. Observed for real: five domains, one stale, DNS not refreshed for 29
# hours while the container sat there reporting a generic KO.
#
# Per domain is five requests every five minutes instead of one. DuckDNS is
# built for a five-minute cadence per domain, so that is not a burden — and it
# buys the thing that matters: a rejected domain is named in the log and takes
# nothing else down with it.

update_one() {
    domain="$1"
    # ip= empty asks DuckDNS to use the source address it sees, which is the
    # whole point on a dynamic connection — nothing here has to discover the
    # public IP, and no third-party "what is my IP" service is involved.
    #
    # The URL carries the token, so it is NEVER logged and curl is never run
    # verbosely. Only the response body is printed.
    # DUCKDNS_ENDPOINT overrides the BASE only, so the query is always
    # appended. It used to replace the whole URL, which was fine while one
    # request carried every domain — with one request per domain that seam
    # silently dropped the `domains` parameter, so a test could no longer tell
    # which domain was being asked about. It cost four failing tests to notice.
    base="${DUCKDNS_ENDPOINT:-https://www.duckdns.org/update}"
    url="${base}?domains=${domain}&token=${DUCKDNS_TOKEN}&ip="
    [ -n "${DUCKDNS_IPV6:-}" ] && url="${url}&ipv6=${DUCKDNS_IPV6}"

    # --fail is deliberately NOT used. DuckDNS answers HTTP 200 for both success
    # and failure, distinguishing them only by a body of "OK" or "KO", so the
    # exit code says nothing about whether the record changed. This is the bug
    # most inline one-liners have.
    body=$(curl -sS --max-time 30 "$url" 2>/dev/null) || return 1
    case "$body" in
        OK*) return 0 ;;
        KO*) return 2 ;;
        *)   log "unexpected response from duckdns for ${domain}: ${body:-<empty>}"
             return 3 ;;
    esac
}

# One domain, with retries. A KO is a configuration error and retrying cannot
# fix it; a network failure is transient and worth a short backoff.
update_with_retries() {
    domain="$1"
    attempt=1
    while :; do
        update_one "$domain" && return 0 || status=$?
        # The status is captured DIRECTLY, not read back after an `if`. A failed
        # `if cmd; then ...; fi` with no else branch leaves `$?` at 0 — the `if`
        # statement itself succeeded — so reading `$?` afterwards always gave 0
        # and the KO case could never be recognised. Every KO was retried as
        # though it were a network blip.
        if [ "$status" -eq 2 ]; then
            log "duckdns REFUSED ${domain} (KO) — it does not belong to this"\
                "token, or no longer exists. Other domains are unaffected;"\
                "remove it from DUCKDNS_DOMAINS to stop this message"
            return 2
        fi
        if [ "$attempt" -ge "$RETRIES" ]; then
            log "giving up on ${domain} for this round after ${attempt} attempt(s)"
            return "$status"
        fi
        backoff=$((attempt * 5))
        log "retrying ${domain} in ${backoff}s"
        sleep "$backoff"
        attempt=$((attempt + 1))
    done
}

log "updating ${DUCKDNS_DOMAINS} every ${INTERVAL}s, one request per domain"

while :; do
    ok=0
    failed=""
    # Split on commas without a subshell, so the counters below survive.
    remaining="${DUCKDNS_DOMAINS},"
    while [ -n "$remaining" ]; do
        domain="${remaining%%,*}"
        remaining="${remaining#*,}"
        [ -n "$domain" ] || continue

        if update_with_retries "$domain"; then
            ok=$((ok + 1))
            # Per domain, so the health check can say WHICH one is stale
            # rather than only that something is.
            mkdir -p "$STATE_DIR/domains"
            date -Iseconds > "$STATE_DIR/domains/$domain"
        else
            failed="${failed}${failed:+ }${domain}"
        fi
    done

    if [ "$ok" -gt 0 ]; then
        # "At least one domain is current." Health is built on this, so a
        # domain you abandoned cannot make the container look broken — which
        # is the whole point of updating them separately.
        date -Iseconds > "$STATE_FILE"
        log "ok: ${ok} domain(s) updated${failed:+, failed: ${failed}}"
    else
        log "NOTHING updated${failed:+ — failed: ${failed}}"
    fi
    sleep "$INTERVAL"
done
