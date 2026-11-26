# X3 capture for the CC-POI (TS 33.128 7.12.6): the eBPF program that copies
# the intercepted media off the media node's core-side interface, and its
# loader. It runs in the media node's network namespace (a sidecar of
# rtpengine) with CAP_BPF, CAP_NET_ADMIN and CAP_SYS_ADMIN (bpffs), or
# privileged.
FROM alpine:latest AS build
RUN apk add --no-cache build-base clang llvm linux-headers libbpf-dev bpftool
WORKDIR /src
COPY . .
RUN make

FROM alpine:latest
# The BPF object is embedded in the binary, so libbpf is all it needs
RUN apk add --no-cache libbpf
COPY --from=build /src/x3cap /usr/local/bin/
ENTRYPOINT ["x3cap"]
CMD ["run", "-i", "eth0"]
