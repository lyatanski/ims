FROM golang:alpine AS build
RUN mkdir -p /usr/share/cgrates/diameter/dict/
RUN go install github.com/cgrates/cgrates/cmd/cgr-engine@latest
#RUN go install github.com/go-delve/delve/cmd/dlv@latest
RUN apk add binutils && strip bin/*

FROM scratch
RUN --mount=type=bind,from=build,source=/lib/,target=/lib \
    --mount=type=bind,from=build,source=/bin/,target=/bin \
    --mount=type=bind,from=build,source=/go/bin/,target=/opt/bin \
    mkdir -p /sbin /usr/share/cgrates/diameter/dict/ \
    && cp /opt/bin/cgr-engine /sbin/
ENTRYPOINT ["cgr-engine", "-logger=*stdout"]
