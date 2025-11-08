FROM golang:alpine AS build

RUN go install github.com/google/go-jsonnet/cmd/jsonnet@latest
RUN go install github.com/google/go-jsonnet/cmd/jsonnet-lint@latest
RUN go install -a github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest

FROM alpine:edge
COPY --from=build /go/bin/* /usr/bin
WORKDIR bla
RUN apk add git
RUN jb init
RUN jb install github.com/grafana/grafonnet/gen/grafonnet-latest@main

