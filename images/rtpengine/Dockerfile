FROM ubuntu:noble

RUN apt update && apt install --no-install-recommends -y rtpengine-daemon

ENTRYPOINT ["rtpengine", "--foreground", "--log-stderr"]
