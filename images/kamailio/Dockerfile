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
        db-dev \
        gawk \
        flex \
        expat-dev \
        openssl-dev \
        hiredis-dev \
        libev-dev \
        libevent-dev \
        libmnl-dev \
        libunistring-dev \
        libwebsockets-dev \
        libxml2-dev \
        linux-headers \
        lksctp-tools-dev \
        lua-dev \
        pcre2-dev \
        icu-dev \
    && ln -s /usr/lib/ninja-build/bin/ninja /usr/local/bin/ \
    && adduser -D build && addgroup build abuild \
    && echo "%abuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/abuild
RUN git clone --depth=1 --branch=pile https://github.com/lyatanski/kamailio.git
RUN cmake -S /kamailio -B /out -G Ninja -D CMAKE_BUILD_TYPE=Release -D MODULE_GROUP_NAME="" -D INCLUDE_MODULES="xhttp xhttp_prom pua cdp cdp_avp db_redis debugger ims_auth ims_charging ims_dialog ims_icscf ims_ipsec_pcscf ims_isc ims_qos ims_registrar_pcscf ims_registrar_scscf ims_usrloc_pcscf ims_usrloc_scscf kex presence pv rr siputils sl textops tm xlog userblocklist acc" \
    && cmake --build /out --target install

FROM alpine:latest
RUN apk add libxml2 hiredis libmnl
COPY --from=build /usr/local/sbin/kamailio /sbin/
COPY --from=build \
    /usr/local/lib/kamailio/modules/* \
    /usr/local/lib/kamailio/modules/
COPY --from=build \
    /kamailio/utils/kamctl/db_redis/kamailio/s_cscf \
    /kamailio/utils/kamctl/db_redis/kamailio/s_cscf_capabilities \
    /kamailio/utils/kamctl/db_redis/kamailio/nds_trusted_domains \
    /etc/cscf/schema/
COPY cscf/ /etc/cscf

ENTRYPOINT ["kamailio", "-DD", "-E"]

