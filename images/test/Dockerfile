# The load generator: pro2call's bindings/examples/ims_test_s5.lua.
#
# It attaches $IMS_SUBS subscribers over S5/S8 (one Create Session each, its own
# PAA and TEIDs), registers every one of them with IMS-AKA + transport-mode ESP,
# then calls them pairwise and — with IMS_SMS=1 — sends SMS over IMS between the
# same pairs, all on one event loop. Its user plane is the eBPF GTP-U datapath
# in gtp/u, attached to the container's own interface, so the UE traffic is real
# G-PDUs on the wire: dedicated bearers and per-UE TFTs are expressible, which
# is what the media phase needs.
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
RUN git clone --depth 1 https://github.com/lyatanski/pro2call.git .
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

# Straight to lua: there is no entrypoint script and nothing to prepare. The
# one thing a wrapper used to do — give the route to the P-CSCF an MTU that
# leaves room for the 36 bytes the datapath adds, so the kernel fragments an
# oversized ESP datagram before the TC hook, where nothing can — the generator
# now does itself over RTNETLINK (net.route_add, $GTPU_INNER_MTU, default
# 1464), on the P-CSCF address the PCO actually returned and only when the
# datapath is up. It needs the pro2call revision that carries it: a tree
# without net.route_add builds and runs, and an answered call's 200 OK will not
# fit.
WORKDIR /opt
ENTRYPOINT ["lua"]
CMD ["ims_test_s5.lua"]
