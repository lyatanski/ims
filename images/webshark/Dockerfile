# webshark - Wireshark in the browser: a static page and a Go server over
# sharkd, built here from Wireshark master with Lua enabled.
#
# Not the published ghcr.io/qxip/webshark, for two independent reasons. Its
# sharkd is 4.5.0 and its own `sharkd -v` says "without Lua", so no plugin can
# be loaded into it at all - and a plugin is what makes a capture answer IMS
# questions instead of packet questions. And its front end is an Angular bundle
# behind a fastify app whose dependencies no longer install into a container
# that starts, none of it touched since August 2024.
#
# So the UI is `src/web` - three files, no framework, no build step - and the
# backend is `src/*.go`, one static binary that talks JSON-RPC to sharkd over a
# pipe. Same features minus the tap menus (Endpoints, Response Time, Statistics,
# Export Objects, Misc), which needed most of that bundle.
#
# plugins/ims.lua is the worked example of the Lua part - it relates SIP to
# Diameter by the subscriber a message is about, so one display filter crosses
# both protocols (the comment at the top of the file explains how, doc/trace.md
# how to use it). Everything in /plugins is loaded by every program in the
# image, so extending it is a mount and nothing else:
#
#     docker run -v ./mine.lua:/plugins/mine.lua ghcr.io/lyatanski/webshark
#
# WIRESHARK_PLUGIN_DIR is what makes that directory the plugin directory: it
# takes precedence over the compiled-in path, and Lua plugin loading walks
# subdirectories, so a mounted tree works too.
#
# Wireshark tracks master, as the other images here do. To pin it instead:
#
#     docker build --build-arg WIRESHARK=v4.6.7 images/webshark

ARG ALPINE=3.22

# --------------------------------------------------------------- sharkd ------
FROM alpine:${ALPINE} AS sharkd
ARG WIRESHARK=master

RUN apk add --no-cache \
        build-base cmake git bison flex python3 \
        glib-dev libgcrypt-dev libxml2-dev c-ares-dev pcre2-dev zlib-dev \
        speexdsp-dev lua5.4-dev

RUN git clone --depth=1 --branch ${WIRESHARK} \
        https://gitlab.com/wireshark/wireshark.git /src

# Three programs out of the tree: sharkd is what the server drives, tshark and
# dftest are what make a plugin testable without a browser (and are what the
# assertion in the last stage uses). Everything else - the GUI, the capture
# tools, the extcaps - is off.
#
# ENABLE_PCAP=OFF because nothing in this image captures; reading a file is
# wiretap's job, not libpcap's. ENABLE_PLUGINS=OFF drops *binary* plugins only:
# the plugin directory itself stays compiled in as long as Lua is on, which is
# the whole point here. Optional Wireshark features are exactly what the -dev
# packages above provide - nothing else is looked for.
RUN cmake -S /src -B /build \
        -D CMAKE_BUILD_TYPE=Release \
        -D BUILD_sharkd=ON -D BUILD_tshark=OFF -D BUILD_dftest=OFF \
        -D BUILD_wireshark=OFF -D BUILD_rawshark=OFF -D BUILD_dumpcap=OFF \
        -D BUILD_capinfos=OFF -D BUILD_captype=OFF -D BUILD_editcap=OFF \
        -D BUILD_mergecap=OFF -D BUILD_reordercap=OFF -D BUILD_text2pcap=OFF \
        -D BUILD_randpkt=OFF -D BUILD_dcerpcidl2wrs=OFF -D BUILD_mmdbresolve=OFF \
        -D BUILD_androiddump=OFF -D BUILD_sshdump=OFF -D BUILD_ciscodump=OFF \
        -D BUILD_dpauxmon=OFF -D BUILD_randpktdump=OFF -D BUILD_wifidump=OFF \
        -D BUILD_udpdump=OFF \
        -D ENABLE_LUA=ON \
        -D ENABLE_PCAP=OFF \
        -D ENABLE_PLUGINS=OFF \
        -D ENABLE_WERROR=OFF \
    && cmake --build /build --parallel $(nproc) \
    && DESTDIR=/out cmake --install /build --strip

# ------------------------------------------------------------------ api ------
FROM golang:alpine AS api
COPY src /src
# CGO off and the symbol table stripped: the result is one file that runs on
# plain alpine with nothing but sharkd next to it. The UI is embedded in it.
RUN cd /src && CGO_ENABLED=0 go vet ./... \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /webshark

# ---------------------------------------------------------------- image ------
FROM alpine:${ALPINE}

# The runtime half of the -dev packages sharkd was built against, and nothing
# else: no node, no npm tree, nothing interpreted. libgcc is not one of them but
# libwireshark needs it for _Unwind_Resume; the node:alpine base this image used
# to sit on happened to carry it, plain alpine does not.
RUN apk add --no-cache \
        glib libgcrypt libxml2 c-ares pcre2 zlib speexdsp lua5.4-libs libgcc

COPY --from=sharkd /out/usr/local /usr/local
COPY --from=api /webshark /usr/bin/
COPY plugins/ /plugins/
# Wireshark's global preferences file, which is read from the data directory of
# the install above. Two things are in it: the hidden port columns the
# sequence-diagram view labels its arrows with, and the ESP preferences that let
# a protected Gm frame be read as the SIP it holds - see the comments in the file.
COPY preferences /usr/local/share/wireshark/preferences

ENV WIRESHARK_PLUGIN_DIR=/plugins \
    CAPTURES=/captures \
    LISTEN=:8085 \
    SHARKD_SESSIONS=4 \
    SHARKD_IDLE=600

RUN mkdir -p /captures
VOLUME /captures
EXPOSE 8085
# Root on purpose: the captures directory is a bind mount owned by whoever runs
# the capture - ptcpdump writes it as root - and uploads have to land in it.
ENTRYPOINT ["webshark"]
