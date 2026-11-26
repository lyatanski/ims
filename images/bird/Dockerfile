FROM alpine

RUN apk add --no-cache bird \
    && mkdir -p /run/bird \
    && bird --version

# -f keeps the daemon in the foreground, -s moves the control socket to a
# directory the chart can share with the probe loop.
ENTRYPOINT ["bird", "-f", "-s", "/run/bird/bird.ctl"]
CMD ["-c", "/etc/bird/bird.conf"]
