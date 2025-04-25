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
RUN git clone --depth=1 https://github.com/kamailio/kamailio.git
RUN cmake -S /kamailio -B /out -G Ninja -D CMAKE_BUILD_TYPE=Release -D MODULE_GROUP_NAME="" -D INCLUDE_MODULES="xhttp xhttp_prom pua cdp cdp_avp db_redis debugger ims_auth ims_charging ims_dialog ims_icscf ims_ipsec_pcscf ims_isc ims_qos ims_registrar_pcscf ims_registrar_scscf ims_usrloc_pcscf ims_usrloc_scscf kex presence pv rr siputils sl textops tm xlog rtpengine userblocklist acc http_client nghttp2" \
    && cmake --build /out --target install

FROM alpine:latest
RUN apk add libxml2 hiredis libmnl libcurl libevent
# nghttp2-libs
COPY --from=build /usr/local/sbin/kamailio /sbin/
COPY --from=build \
    /usr/local/lib/kamailio/modules/* \
    /usr/local/lib/kamailio/modules/
RUN --mount=type=bind,from=build,source=/kamailio/utils/kamctl/db_redis/kamailio/,target=/dbmap \
    mkdir -p /etc/cscf/schema/proxy \
    && cp /dbmap/pcscf_location /etc/cscf/schema/proxy/location \
    && cp /dbmap/dialog_in /dbmap/dialog_out /dbmap/dialog_vars /etc/cscf/schema/proxy \
    && mkdir -p /etc/cscf/schema/interrogating \
    && cp /dbmap/s_cscf /dbmap/s_cscf_capabilities /dbmap/nds_trusted_domains /etc/cscf/schema/interrogating \
    && mkdir -p /etc/cscf/schema/serving \
    && cp /dbmap/dialog_in /dbmap/dialog_out /dbmap/dialog_vars /etc/cscf/schema/serving \
    && cp /dbmap/contact /dbmap/impu /dbmap/impu_contact /dbmap/subscriber_scscf /dbmap/impu_subscriber /etc/cscf/schema/serving \
    && cp /dbmap/ro_session /etc/cscf/schema/serving
COPY cscf/ /etc/cscf

ENTRYPOINT ["kamailio", "-DD", "-E"]

