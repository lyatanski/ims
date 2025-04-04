FROM alpine:latest AS build

RUN apk --no-cache upgrade \
    && apk add --no-cache \
        abuild sudo \
        git \
        gcc \
        build-base \
        cmake \
        ninja-build \
        bison \
        gawk \
        flex \
        openssl-dev \
        hiredis-dev \
        libevent-dev \
        libmnl-dev \
        libunistring-dev \
        libwebsockets-dev \
        libxml2-dev \
        icu-dev \
        curl-dev \
        nghttp2-dev \
    && ln -s /usr/lib/ninja-build/bin/ninja /usr/local/bin/ \
    && adduser -D build && addgroup build abuild \
    && echo "%abuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/abuild
RUN git clone --depth=1 --branch=pile https://github.com/lyatanski/kamailio.git
RUN cmake -S /kamailio -B /out -G Ninja -D CMAKE_BUILD_TYPE=Release -D MODULE_GROUP_NAME="" -D INCLUDE_MODULES="xhttp xhttp_prom pua cdp cdp_avp db_redis debugger ims_auth ims_charging ims_dialog ims_icscf ims_ipsec_pcscf ims_isc ims_qos ims_registrar_pcscf ims_registrar_scscf ims_usrloc_pcscf ims_usrloc_scscf kex presence pv rr siputils sl textops tm xlog rtpengine userblocklist acc http_client nghttp2" \
    && cmake --build /out --target install

FROM alpine:latest
RUN apk add libxml2 hiredis libmnl libcurl libevent
# nghttp2-libs
COPY --from=build /usr/local/sbin/kamailio /sbin/
COPY --from=build \
    /usr/local/lib/kamailio/modules/* \
    /usr/local/lib/kamailio/modules/
COPY --from=build \
    /kamailio/utils/kamctl/db_redis/kamailio/dialog_in \
    /kamailio/utils/kamctl/db_redis/kamailio/dialog_out \
    /kamailio/utils/kamctl/db_redis/kamailio/dialog_vars \
\
    /kamailio/utils/kamctl/db_redis/kamailio/pcscf_location \
\
    /kamailio/utils/kamctl/db_redis/kamailio/s_cscf \
    /kamailio/utils/kamctl/db_redis/kamailio/s_cscf_capabilities \
    /kamailio/utils/kamctl/db_redis/kamailio/nds_trusted_domains \
\
    /kamailio/utils/kamctl/db_redis/kamailio/contact \
    /kamailio/utils/kamctl/db_redis/kamailio/impu \
    /kamailio/utils/kamctl/db_redis/kamailio/impu_contact \
    /kamailio/utils/kamctl/db_redis/kamailio/subscriber_scscf \
    /kamailio/utils/kamctl/db_redis/kamailio/impu_subscriber \
    /kamailio/utils/kamctl/db_redis/kamailio/ro_session \
\
    /kamailio/utils/kamctl/db_redis/kamailio/presentity \
    /kamailio/utils/kamctl/db_redis/kamailio/active_watchers \
    /kamailio/utils/kamctl/db_redis/kamailio/watchers \
    /kamailio/utils/kamctl/db_redis/kamailio/xcap \
    /kamailio/utils/kamctl/db_redis/kamailio/pua \
\
    /kamailio/utils/kamctl/db_redis/kamailio/globalblocklist \
    /kamailio/utils/kamctl/db_redis/kamailio/userblocklist \
\
    /kamailio/utils/kamctl/db_redis/kamailio/acc_cdrs \
\
    /etc/cscf/schema/
COPY cscf/ /etc/cscf

ENTRYPOINT ["kamailio", "-DD", "-E"]

