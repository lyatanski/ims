FROM golang:alpine AS build
RUN go install github.com/cgrates/cgrates/cmd/cgr-console@master
RUN apk add binutils && strip bin/*

FROM scratch
COPY --from=build /go/bin/cgr-console /sbin/cgr-console
ENTRYPOINT ["cgr-console"]

