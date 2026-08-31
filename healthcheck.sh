#!/bin/sh
# Unhealthy when the last SUCCESSFUL update is too old.
#
# This is the reason the image exists. Liveness is not the question — the loop
# will happily keep running while every request fails. The question is whether
# DNS still points here, and the only honest evidence is a recent success.
set -eu

INTERVAL="${INTERVAL:-300}"
STATE_FILE="${STATE_DIR:-/var/lib/duckdns}/last-success"

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
echo "last successful update ${age}s ago"
