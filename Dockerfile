# Alpine plus curl rather than a language runtime: the whole job is one HTTP
# request and a sleep, so there is no reason to ship an interpreter and its
# dependency tree. Built size is ~21MB, most of which is alpine and curl
# themselves.
#
# `curlimages/curl` would be a slightly smaller starting point, but it ships its
# own `curl` user at uid 100 and no writable state directory, and this image
# needs both a known uid and somewhere to record the last success. Starting from
# alpine keeps that explicit.
FROM alpine:3.21

# curl is deliberately unpinned: an unpinned package picks up security fixes on
# every rebuild, which matters more here than byte-identical reproducibility for
# a container whose only job is one outbound request. tzdata is only so log
# timestamps can follow TZ instead of always being UTC — drop it to save ~3MB if
# UTC logs are fine.
RUN apk add --no-cache curl tzdata \
    # Non-root. This container needs no privileges at all — it makes one
    # outbound HTTPS request — so running as root would be privilege for
    # nothing.
    && addgroup -g 10001 -S duckdns \
    && adduser -u 10001 -S -G duckdns -H -s /sbin/nologin duckdns \
    && mkdir -p /var/lib/duckdns \
    && chown duckdns:duckdns /var/lib/duckdns

COPY update.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/update.sh /usr/local/bin/healthcheck.sh

USER duckdns
VOLUME ["/var/lib/duckdns"]

# The state file records the last SUCCESS, and this is what turns a silently
# broken updater into a visibly unhealthy container.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=2 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/update.sh"]
