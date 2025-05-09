FROM golang:alpine AS build
RUN go install github.com/cgrates/cgrates/cmd/cgr-loader@master
RUN apk add binutils && strip bin/*

FROM scratch
COPY --from=build /go/bin/cgr-loader /sbin/cgr-loader
ENTRYPOINT ["cgr-loader", "-verbose"]

