#!/usr/bin/env bash
# Verifies the behaviour that distinguishes this from an inline shell loop:
# that a FAILING updater becomes visibly unhealthy. Uses a mock endpoint, so no
# real DuckDNS token is needed and no real DNS record is touched.
set -uo pipefail

IMAGE="${IMAGE:-duckdns-updater:test}"
NET=duckdns-test-net
pass=0; fail=0

cleanup() {
  docker rm -f mock updater >/dev/null 2>&1
  docker network rm $NET >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

check() {  # description, expected, actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 — expected '$2', got '$3'"; fail=$((fail+1)); fi
}

docker network create $NET >/dev/null

start_mock() {  # body
  docker rm -f mock >/dev/null 2>&1
  docker run -d --name mock --network $NET python:3.12-alpine python -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.send_header('Content-Type','text/plain'); s.end_headers()
        s.wfile.write(b'$1')
    def log_message(s,*a): pass
http.server.HTTPServer(('',8000), H).serve_forever()
" >/dev/null
  sleep 3
}

start_updater() {  # extra docker args...
  docker rm -f updater >/dev/null 2>&1
  docker run -d --name updater --network $NET \
    -e DUCKDNS_DOMAINS=example \
    -e INTERVAL=5 -e RETRIES=2 \
    --health-start-period=2s --health-interval=3s --health-retries=1 \
    "$@" "$IMAGE" >/dev/null
}

health() { docker inspect --format '{{.State.Health.Status}}' updater 2>/dev/null; }

wait_health() {  # wanted, seconds
  for _ in $(seq 1 "$2"); do [ "$(health)" = "$1" ] && return 0; sleep 2; done
  return 1
}

echo "── a working endpoint makes the container healthy"
start_mock OK
start_updater -e DUCKDNS_TOKEN=tok -e DUCKDNS_ENDPOINT=http://mock:8000/
wait_health healthy 30
check "reports healthy" healthy "$(health)"
check "logs the success" "yes" "$([ "$(docker logs updater 2>&1 | grep -cE ' ok$')" -gt 0 ] && echo yes || echo no)"
check "never logs the token" "yes" "$([ "$(docker logs updater 2>&1 | grep -c tok)" -gt 0 ] && echo no || echo yes)"

echo "── a KO response makes it UNHEALTHY (the whole point)"
start_mock KO
start_updater -e DUCKDNS_TOKEN=tok -e DUCKDNS_ENDPOINT=http://mock:8000/
wait_health unhealthy 40
check "reports unhealthy" unhealthy "$(health)"
check "explains KO" "yes" "$([ "$(docker logs updater 2>&1 | grep -ci 'refused the update')" -gt 0 ] && echo yes || echo no)"
check "does NOT retry a KO (config error, not a blip)" "0" "$(docker logs updater 2>&1 | grep -ci 'retrying in')"
check "is still running, not crashed" "true" "$(docker inspect -f '{{.State.Running}}' updater)"

echo "── an unreachable endpoint retries, then goes unhealthy"
docker rm -f mock >/dev/null 2>&1
start_updater -e DUCKDNS_TOKEN=tok -e DUCKDNS_ENDPOINT=http://mock:8000/
wait_health unhealthy 40
check "reports unhealthy" unhealthy "$(health)"
check "retried before giving up" "yes" "$([ "$(docker logs updater 2>&1 | grep -ci 'retrying in')" -gt 0 ] && echo yes || echo no)"

echo "── a token with a trailing newline still works"
start_mock OK
printf 'tok\n' > /tmp/duckdns-token-test
start_updater -e DUCKDNS_TOKEN='tok
' -e DUCKDNS_ENDPOINT=http://mock:8000/
wait_health healthy 30
check "whitespace is stripped" healthy "$(health)"

echo "── a missing token fails fast instead of looping"
docker rm -f updater >/dev/null 2>&1
out=$(docker run --rm --network $NET -e DUCKDNS_DOMAINS=example "$IMAGE" 2>&1)
check "exits non-zero" "yes" "$([ $? -ne 0 ] && echo yes || echo no)"
check "says what is missing" "yes" "$([ "$(echo "$out" | grep -c DUCKDNS_TOKEN)" -gt 0 ] && echo yes || echo no)"

echo "── missing domains fails fast too"
out=$(docker run --rm --network $NET -e DUCKDNS_TOKEN=tok "$IMAGE" 2>&1)
check "says what is missing" "yes" "$([ "$(echo "$out" | grep -c DUCKDNS_DOMAINS)" -gt 0 ] && echo yes || echo no)"

echo "── runs as a non-root user"
start_mock OK
start_updater -e DUCKDNS_TOKEN=tok -e DUCKDNS_ENDPOINT=http://mock:8000/
sleep 3
check "uid is not 0" "10001" "$(docker exec updater id -u)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
