#!/bin/sh
# Unhealthy when NO domain has been updated recently.
#
# This is the reason the image exists. Liveness is not the question — the loop
# will happily keep running while every request fails. The question is whether
# DNS still points here, and the only honest evidence is a recent success.
#
# "No domain" and not "every domain", deliberately. A domain removed at DuckDNS
# or left in DUCKDNS_DOMAINS after you stopped wanting it is refused forever,
# and letting that turn the container red was wrong in three ways: it says the
# service is broken when it is doing its job for every other domain, it makes
# `compose up --wait` time out so the app cannot be deployed at all, and the
# fix — edit an environment variable — has nothing to do with the container.
# The rejected domain is named in the log every round instead.
#
# Stale domains are still REPORTED here, so the information is not lost; it
# just does not decide the exit code.
set -eu

INTERVAL="${INTERVAL:-300}"
STATE_DIR="${STATE_DIR:-/var/lib/duckdns}"
STATE_FILE="$STATE_DIR/last-success"
STATE_DIR_DOMAINS="$STATE_DIR/domains"

# Three intervals of tolerance: one failure plus its retries should not flap the
# health status, but a persistent failure must surface well before anything that
# depends on DNS (a certificate renewal) comes due.
MAX_AGE=$((INTERVAL * 3))

[ -f "$STATE_FILE" ] || { echo "no successful update yet"; exit 1; }

age=$(( $(date +%s) - $(date -r "$STATE_FILE" +%s) ))
[ "$age" -le "$MAX_AGE" ] || {
    echo "last successful update was ${age}s ago (limit ${MAX_AGE}s)"
    exit 1
}
# Name any domain that is behind, without failing for it.
#
# Driven by DUCKDNS_DOMAINS, not by what is in the state directory. A domain
# that has NEVER updated has no state file at all — and that is precisely the
# one worth naming, since it is either misspelled or no longer belongs to the
# token. An earlier version listed only files that existed and were old, so it
# stayed silent about exactly the case it was written for; the test caught it.
stale=""
remaining="${DUCKDNS_DOMAINS:-},"
while [ -n "$remaining" ]; do
    domain="${remaining%%,*}"
    remaining="${remaining#*,}"
    [ -n "$domain" ] || continue
    marker="$STATE_DIR_DOMAINS/$domain"
    if [ ! -f "$marker" ]; then
        stale="${stale}${stale:+ }${domain}(never)"
    else
        d_age=$(( $(date +%s) - $(date -r "$marker" +%s) ))
        [ "$d_age" -le "$MAX_AGE" ] || stale="${stale}${stale:+ }${domain}"
    fi
done
echo "last successful update ${age}s ago${stale:+; stale: ${stale}}"
