FROM alpine AS build
ARG VERSION=2.7.2
RUN apk add alpine-sdk bison flex git cmake meson bash sudo linux-headers bsd-compat-headers yaml-dev lksctp-tools-dev gnutls-dev libgcrypt-dev libidn-dev mongo-c-driver-dev libmicrohttpd-dev curl-dev nghttp2-dev talloc-dev
RUN wget -qO- https://github.com/open5gs/open5gs/archive/refs/tags/v${VERSION}.tar.gz | tar -xzf-
WORKDIR open5gs-${VERSION}
RUN meson build --prefix=/opt
RUN ninja -C build install

FROM alpine
RUN apk add yaml lksctp-tools gnutls libgcrypt libidn mongo-c-driver libmicrohttpd curl nghttp2 talloc
COPY --from=build /opt /opt
ADD entry.sh /opt/
ENTRYPOINT ["/opt/entry.sh"]

