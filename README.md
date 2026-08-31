# duckdns-updater

Keeps a DuckDNS hostname pointed at your current public IP. One small container,
no dependencies, and — the reason it exists — **it reports unhealthy when it
stops working.**

```bash
docker run -d --name duckdns --restart unless-stopped \
  -e DUCKDNS_DOMAINS=myhost \
  -e DUCKDNS_TOKEN=your-token \
  georgegozal/duckdns-updater:1
```

`DUCKDNS_DOMAINS` is comma-separated and takes the subdomain only, without
`.duckdns.org`: `myhost,another,third`.

## Why not three lines in a compose file

The usual inline version is a `while` loop around `curl`, and it works. What it
cannot do is fail:

```yaml
entrypoint: [sh, -c, 'while :; do curl -fsS "https://www.duckdns.org/update?..."; sleep 300; done']
```

DuckDNS answers **HTTP 200 for both success and failure**, distinguishing them
only by a body of `OK` or `KO`. So `curl --fail` succeeds on a rejected update,
the loop prints `KO`, sleeps, and the container stays contentedly `running`
forever.

That matters because of what depends on it. On a residential connection this
record is what lets Let's Encrypt find your host at renewal time, roughly every
60 days. A stale record means the challenge reaches the wrong address and
renewal fails — and with an inline loop you find out when the certificate
expires, months after the cause.

This image checks the response body, records the last **successful** update, and
fails its healthcheck when that becomes too old. `docker ps` shows the problem
while there is still time to fix it.

## Configuration

| Variable | Default | |
|---|---|---|
| `DUCKDNS_DOMAINS` | *required* | Comma-separated subdomains, no `.duckdns.org` |
| `DUCKDNS_TOKEN` | *required* | Your DuckDNS token |
| `DUCKDNS_TOKEN_FILE` | — | Read the token from a file instead — a Docker secret or a tightly-permissioned mount |
| `INTERVAL` | `300` | Seconds between updates |
| `RETRIES` | `3` | Attempts per round, on *network* failure only |
| `DUCKDNS_IPV6` | — | An AAAA address to set alongside the A record |
| `STATE_DIR` | `/var/lib/duckdns` | Where the last-success timestamp lives |
| `TZ` | UTC | Timezone for log timestamps |

Whitespace is stripped from the token. A trailing newline — which a token
pasted into an `.env` file or a secret usually keeps — otherwise produces a bare
`KO` with no hint about why.

The public IP is never looked up. `ip=` is sent empty, so DuckDNS uses the source
address it sees, which is both correct behind NAT and means no third-party
"what is my IP" service is involved.

## Health

```
HEALTHCHECK  interval=60s  timeout=10s  start-period=30s  retries=2
```

Unhealthy once the last success is older than `INTERVAL * 3` — enough tolerance
that one failed round does not flap, soon enough that a persistent failure
surfaces long before a certificate renewal comes due.

```bash
docker inspect --format '{{.State.Health.Status}}' duckdns
docker inspect --format '{{json .State.Health.Log}}' duckdns | tail -1
```

A `KO` is treated as a configuration error and is **not** retried — retrying
cannot fix a wrong token, and hammering DuckDNS about it is rude. Network
failures are retried with a short backoff instead of waiting a whole interval.

## compose

```yaml
services:
  duckdns:
    image: georgegozal/duckdns-updater:1
    container_name: duckdns
    restart: unless-stopped
    environment:
      DUCKDNS_DOMAINS: ${DUCKDNS_DOMAINS:?}
      DUCKDNS_TOKEN: ${DUCKDNS_TOKEN:?}
    volumes:
      # Keeps the last-success timestamp across restarts, so a restart does not
      # reset the health window and hide a problem that was already showing.
      - duckdns_state:/var/lib/duckdns
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

volumes:
  duckdns_state:
```

## Tests

```bash
docker build -t duckdns-updater:test .
./test.sh
```

No DuckDNS token needed and no real record touched: the tests point the updater
at a mock endpoint via `DUCKDNS_ENDPOINT` and assert on behaviour — that a `KO`
turns the container unhealthy, that a `KO` is not retried, that the token never
appears in the logs, that a missing variable fails fast rather than looping, and
that it runs as uid 10001.

Two bugs were found by writing them, both worth knowing about if you edit
`update.sh`:

- **`$?` after a failed `if` is 0, not the command's status.** `if update; then
  … fi` with no `else` succeeds *as a statement* when the condition fails, so
  reading `$?` afterwards always gave 0 and the `KO` case could never be
  recognised — every `KO` was retried as a network blip. The status is captured
  directly now.
- **`grep -q` under `set -o pipefail` reports no match when there is one.**
  `grep -q` exits at the first match, the upstream command takes SIGPIPE, and
  `pipefail` propagates that as a failed pipeline. The tests count matches
  instead.

## Publishing

Build for both architectures. A plain `docker build` produces only the
architecture of the machine you are on, and an image pushed that way will not
start on the other:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t georgegozal/duckdns-updater:1 --push .
```
