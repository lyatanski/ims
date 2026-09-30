##
## rtpengine, built from source against a purpose-built ffmpeg so that the codec
## list is as complete as licensing and Alpine allow.
##
## No distribution package is good enough here.  Ubuntu noble ships 11.5.1, old
## enough to be missing `redis-subscribe` and much else.  Alpine's own package
## builds without bcg729 -- no G.729 -- and against an ffmpeg that carries the
## AMR, GSM, iLBC and Speex *decoders* but none of their *encoders*, which
## leaves the daemon able to receive those codecs and never to produce one.  For
## an IMS media relay whose day job is PCMA <-> AMR that is the wrong half.
##
## Two things this image tries to keep true over time:
##
##   * dependencies are discovered, not listed -- deps.sh reads them out of the
##     rtpengine tree on every build, so one the developers add tomorrow is
##     installed tomorrow; runtime.sh does the same for the runtime image by
##     reading the SONAMEs out of the binaries it just built;
##   * codec coverage is asserted, not assumed -- codecs.sh fails the build if
##     `rtpengine --codecs` ever reports less than it does today, because an
##     optional transcoding library that goes missing still compiles cleanly.
##

ARG ALPINE=latest
ARG FFMPEG=n8.1.2
ARG LIBILBC=v3.0.4
ARG BCG729=1.1.2
ARG RTPENGINE=master


##
## The codec libraries, and the ffmpeg that fronts them.
##
FROM alpine:${ALPINE} AS media
ARG FFMPEG LIBILBC BCG729

# One entry per external codec ffmpeg cannot implement itself: the configure
# switch, and the Alpine -dev package behind it.  An empty package means the
# library is built from source below because Alpine does not carry it.  ffmpeg's
# own builtin codecs cover the rest -- G.722, G.723.1, G.726, L16, AC-3, and the
# decode-only EVRC, QCELP and ATRAC that no encoder exists for anywhere.
ARG CODECS="\
    opus:opus-dev \
    opencore-amrnb:opencore-amr-dev \
    opencore-amrwb:opencore-amr-dev \
    vo-amrwbenc:vo-amrwbenc-dev \
    gsm:gsm-dev \
    speex:speex-dev \
    mp3lame:lame-dev \
    vorbis:libvorbis-dev \
    ilbc: \
"

RUN apk add --no-cache build-base cmake git nasm perl pkgconf \
    && apk add --no-cache $(printf '%s\n' ${CODECS} | cut -d: -f2 | grep . | sort -u)

# iLBC and G.729 are the two codecs rtpengine wants that Alpine does not
# package at all, so they are built here.  libilbc needs --recurse-submodules:
# it carries the WebRTC iLBC sources, which include abseil headers from one.
RUN git clone --depth=1 --recurse-submodules --shallow-submodules \
        -b ${LIBILBC} https://github.com/TimothyGu/libilbc.git /src/ilbc \
    && cmake -S /src/ilbc -B /src/ilbc/build -G "Unix Makefiles" \
        -D CMAKE_BUILD_TYPE=Release -D BUILD_SHARED_LIBS=ON \
    && cmake --build /src/ilbc/build --target install

# bcg729 stays a static archive: it is 200 kB, rtpengine is the only thing that
# would ever link it, and that is one fewer .so in the runtime image.  PIC has
# to be forced on because rtpengine links itself -pie.
RUN git clone --depth=1 -b ${BCG729} https://github.com/BelledonneCommunications/bcg729.git /src/bcg729 \
    && cmake -S /src/bcg729 -B /src/bcg729/build -G "Unix Makefiles" \
        -D CMAKE_INSTALL_PREFIX=/usr -D CMAKE_BUILD_TYPE=Release \
        -D BUILD_SHARED_LIBS=OFF -D CMAKE_POSITION_INDEPENDENT_CODE=ON \
    && cmake --build /src/bcg729/build --target install

# --disable-autodetect keeps the build honest: ffmpeg picks up nothing that is
# not asked for by name, so the codec set is the one listed above and not
# whatever happened to be installed.  --enable-version3 is what the opencore-amr
# and vo-amrwbenc licences require, and rtpengine is GPL-3.0 itself, so the
# combined result stays distributable.
RUN git clone --depth=1 -b ${FFMPEG} https://github.com/FFmpeg/FFmpeg.git /src/ffmpeg \
    && cd /src/ffmpeg \
    && ./configure \
        --prefix=/usr/local \
        --enable-shared --disable-static \
        --enable-gpl --enable-version3 \
        --disable-autodetect \
        --disable-programs --disable-doc \
        --disable-avdevice \
        --disable-network \
        $(printf '%s\n' ${CODECS} | cut -d: -f1 | sed 's/^/--enable-lib/') \
    && make -j"$(nproc)" \
    && make install


##
## rtpengine itself.
##
FROM alpine:${ALPINE} AS build
ARG RTPENGINE

# The toolchain, and only the toolchain.  Every library below it is discovered
# by deps.sh from the rtpengine tree: bash and perl because upstream's
# utils/gen-*-flags and utils/const_str_hash are written in them, linux-headers
# because daemon/nftables.c talks to nf_tables directly, pax-utils for
# runtime.sh.
RUN apk add --no-cache build-base git bash perl pkgconf linux-headers pax-utils

COPY deps.sh codecs.sh runtime.sh /build/

COPY --from=media /usr/local /usr/local
COPY --from=media /usr/lib/libbcg729.a /usr/lib/
COPY --from=media /usr/lib/pkgconfig/libbcg729.pc /usr/lib/pkgconfig/
COPY --from=media /usr/include/bcg729 /usr/include/bcg729

# The codec libraries the source-built ffmpeg links against -- asked of ffmpeg
# itself rather than written down a second time, so the CODECS list above stays
# the only place they are named.
RUN apk add --no-cache $(/build/runtime.sh /usr/local/lib)

RUN git clone --depth=1 -b ${RTPENGINE} https://github.com/sipwise/rtpengine.git /src/rtpengine

# Carried until upstream takes them -- each patch header says what it fixes and
# why.  `git apply` fails the build if one stops applying, which is what we want:
# silently dropping one here would silently drop a codec.
COPY patches/ /patches/
RUN git -C /src/rtpengine apply --verbose /patches/*.patch

RUN /build/deps.sh /src/rtpengine

# Upstream's own build and install, driven as they are meant to be driven -- no
# overridden variables, no substituted install steps -- so that a binary or a
# helper upstream adds lands in the image without a change here.
RUN make -C /src/rtpengine -j"$(nproc)" \
    && make -C /src/rtpengine install DESTDIR=/stage

# `make install` also leaves three perl helpers behind, and none of them can
# work here.  rtpengine-ng-client wants NGCP::Rtpengine, which `make install`
# does not install at all.  rtpengine-ctl and rtpengine-get-table want perl plus
# Config::Tiny -- 38 MB, a third of this image -- to drive a `listen-cli` socket
# and a kernel table that neither compose.yml nor the chart turns on, and the
# kernel module could not ship in an image anyway since it has to match the host
# kernel.  So drop whatever the runtime image will not be able to run, by rule
# rather than by name, so that a fourth helper is handled the same way.
RUN find /stage -type f -perm -u+x | while read -r f; do \
        interp=$(sed -n '1s|^#![[:space:]]*\([^[:space:]]*\).*|\1|p' "$f"); \
        case $interp in '' | /bin/sh | /bin/busybox) continue ;; esac; \
        echo "dropping ${f#/stage}: needs $interp, absent from the runtime image"; \
        rm -f "$f"; \
    done

RUN /build/codecs.sh /stage/usr/bin/rtpengine \
    && /build/runtime.sh /stage /usr/local/lib > /stage/runtime-deps


##
## The image that ships.
##
FROM alpine:${ALPINE}

COPY --from=media /usr/local/lib/ /usr/local/lib/
COPY --from=build /stage/usr/ /usr/
COPY --from=build /stage/runtime-deps /tmp/runtime-deps

# The package list runtime.sh read out of the binaries themselves.
RUN apk add --no-cache $(cat /tmp/runtime-deps) \
    && rm -rf /tmp/runtime-deps /usr/local/lib/pkgconfig

ENTRYPOINT ["rtpengine", "--foreground", "--log-stderr"]
