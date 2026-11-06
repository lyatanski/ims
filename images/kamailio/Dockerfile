# Build exactly the modules the cfgs load. Kept in its own stage so a cfg edit
# that leaves the module set unchanged does not invalidate the cmake layer.
FROM alpine:latest AS modules
COPY cscf/ /cfg/cscf/
COPY as/ /cfg/as/
RUN grep -rhE '^[[:space:]]*loadmodule' /cfg \
    | sed -E 's/.*"([^"/.]+)(\.so)?".*/\1/' | sort -u > /modules.txt

FROM alpine:latest AS build

RUN apk --no-cache upgrade \
    && apk add --no-cache \
        git \
        gcc \
        build-base \
        cmake \
        ninja-build \
        bison \
        gawk \
        flex \
        openssl-dev \
        hiredis-dev hiredis-ssl \
        libevent-dev \
        libmnl-dev \
        libunistring-dev \
        libwebsockets-dev \
        libxml2-dev \
        icu-dev \
        curl-dev \
        nghttp2-dev \
        mariadb-dev \
    && ln -s /usr/lib/ninja-build/bin/ninja /usr/local/bin/
# Re-checks master on every build, so a cached clone never lags upstream
ADD --keep-git-dir https://github.com/kamailio/kamailio.git#master /kamailio
COPY patches/ /patches/
RUN for p in /patches/*.patch; do echo "== $p"; git -C /kamailio apply --verbose "$p" || exit 1; done
COPY --from=modules /modules.txt /
RUN cmake -S /kamailio -B /out -G Ninja -D CMAKE_BUILD_TYPE=Release \
        -D MODULE_GROUP_NAME="" \
        -D INCLUDE_MODULES="$(cat /modules.txt)" \
    && cmake --build /out --target install

FROM alpine:latest
RUN apk add libxml2 hiredis hiredis-ssl libmnl libcurl libevent openssl
# nghttp2-libs
COPY --from=build /usr/local/sbin/kamailio /sbin/
COPY --from=build \
    /usr/local/lib/kamailio/modules/* \
    /usr/local/lib/kamailio/modules/
RUN --mount=type=bind,from=build,source=/kamailio/utils/kamctl/db_redis/kamailio/,target=/dbmap \
    mkdir -p /etc/cscf/schema/proxy \
    && cp /dbmap/pcscf_location /etc/cscf/schema/proxy/location \
    && cp /dbmap/dialog_in /dbmap/dialog_out /dbmap/dialog_vars /etc/cscf/schema/proxy \
    && cp /dbmap/pua /etc/cscf/schema/proxy \
    && mkdir -p /etc/cscf/schema/interrogating \
    && cp /dbmap/s_cscf /dbmap/s_cscf_capabilities /dbmap/nds_trusted_domains /etc/cscf/schema/interrogating \
    && mkdir -p /etc/cscf/schema/serving \
    && cp /dbmap/dialog_in /dbmap/dialog_out /dbmap/dialog_vars /etc/cscf/schema/serving \
    && cp /dbmap/contact /dbmap/impu /dbmap/impu_contact /dbmap/subscriber_scscf /dbmap/impu_subscriber /etc/cscf/schema/serving \
    && cp /dbmap/ro_session /etc/cscf/schema/serving \
    && mkdir -p /etc/as/schema/telephony \
    && cp /dbmap/userblocklist /etc/as/schema/telephony/ocb \
    && cp /dbmap/userblocklist /etc/as/schema/telephony/icb \
    && cp /dbmap/globalblocklist /etc/as/schema/telephony
COPY cscf/ /etc/cscf
COPY as/ /etc/as

ENTRYPOINT ["kamailio", "-DD", "-E"]

