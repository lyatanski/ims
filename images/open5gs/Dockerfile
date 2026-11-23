FROM alpine AS build
RUN apk add alpine-sdk bison flex git cmake meson bash sudo linux-headers bsd-compat-headers yaml-dev lksctp-tools-dev gnutls-dev libgcrypt-dev libidn-dev mongo-c-driver-dev libmicrohttpd-dev curl-dev nghttp2-dev talloc-dev
RUN git clone https://github.com/lyatanski/open5gs.git
WORKDIR open5gs
# Carried until upstream takes them -- each patch header says what it fixes and
# why. `git apply` fails the build if one stops applying, which is what we want:
# a silently unpatched image answers an LIR for a number it does not have with
# a code the I-CSCF cannot map, and the UE gets 500 instead of 604.
COPY patches/ /patches/
RUN git apply --verbose /patches/*.patch
# musl gives a thread 128 KiB of stack unless a loaded object's PT_GNU_STACK
# asks for more. The daemons run their event loop in such a thread, and
# ogs_pfcp_send_error_message() alone puts a 145 KB message on the stack: any
# PFCP error answer from the UPF overflowed it (SIGSEGV), and a UPF restarted
# into PFCP restoration answered an error and died again. 8 MiB is musl's cap.
# The C libraries (libogscore, ...) carry it; musl honours it from any object
# loaded at startup, so the daemons, linked as C++ for libtins, need not.
RUN meson build --prefix=/opt -Dc_link_args=-Wl,-z,stack-size=8388608
RUN ninja -C build install

FROM alpine
RUN apk add yaml lksctp-tools gnutls libgcrypt libidn mongo-c-driver libmicrohttpd curl nghttp2 talloc
COPY --from=build /opt /opt
ADD entry.sh /opt/
ENTRYPOINT ["/opt/entry.sh"]

