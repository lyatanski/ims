# webshark - Wireshark in the browser: a static page and a Go server over
# sharkd, built here from Wireshark master with Lua enabled.
#
# plugins/ims.lua relates SIP to Diameter by the subscriber identity
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
RUN cd /src && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /webshark

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
