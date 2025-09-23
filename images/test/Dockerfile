FROM golang:alpine AS build
COPY ./src /go
RUN go build -o gtp

FROM ghcr.io/lyatanski/doubango
COPY --from=build /go/gtp /usr/bin/
COPY ./src/sip.py /opt/
