FROM alpine:edge AS build

# Build dependencies, as pro2call's own Dockerfile groups them:
#
#   build-base cmake ninja pkgconf   core C toolchain + build system
#   openssl-dev                      net module (OpenSSL::SSL)
#   go                               gtp/gen + diam/gen code generators
#   clang libbpf-dev bpftool         gtp/u eBPF datapath (BpfCompile.cmake)
#   linux-headers                    kernel UAPI headers for the BPF object
#   swig lua5.1-dev                  the Lua bindings the script is written in
#   git                              fetching the tree below
#
# Without clang/bpftool/libbpf gtp/u still builds, with the datapath stubbed
# out (GTPU_EBPF_DISABLED) — and then nothing decapsulates the downlink, so
# they are not optional here.
RUN apk add --no-cache \
    build-base \
    cmake \
    ninja \
    pkgconf \
    linux-headers \
    openssl-dev \
    go \
    clang \
    swig \
    lua5.1-dev \
    libbpf-dev \
    bpftool \
    git

ENV GOPATH=/tmp/go
ENV GOCACHE=/tmp/go/cache

WORKDIR /src

ARG PRO2CALL_REF=main
RUN git init -q . \
 && git remote add origin https://github.com/lyatanski/pro2call.git \
 && git fetch -q --depth 1 origin "$PRO2CALL_REF" \
 && git checkout -q FETCH_HEAD \
 && git rev-parse HEAD > /REVISION
RUN cmake -B out -G Ninja \
 && cmake --build out --target \
    gtp_lua net_lua sip_lua sdp_lua sms_lua rtp_lua ipsec diam_lua json_lua


FROM alpine:edge

# Runtime deps of the modules: liblua5.1 (lua5.1 pulls lua5.1-libs) plus
# libstdc++/libgcc for the SWIG C++ facades, libcrypto for Milenage and MD5,
# and libbpf for the datapath.
RUN apk add --no-cache lua5.1 libstdc++ libcrypto3 libbpf

# /usr/lib/lua/5.1 is already on Lua's default package.cpath, so `require "gtp"`
# resolves with no LUA_CPATH in the environment.
COPY --from=build /src/out/bindings/lua/*.so /usr/lib/lua/5.1/
COPY --from=build /src/bindings/examples/*.lua /opt/
COPY --from=build /REVISION /opt/REVISION

WORKDIR /opt
ENTRYPOINT ["lua"]
CMD ["ims_test_s5.lua"]
