FROM alpine:latest AS build

RUN apk --no-cache upgrade \
    && apk add --no-cache \
        abuild sudo \
        git \
        gcc \
        build-base \
        cmake \
        bison \
        db-dev \
        gawk \
        flex \
        confuse-dev \
        curl-dev \
        expat-dev \
        freeradius-client-dev \
        hiredis-dev \
        jansson-dev \
        json-c-dev \
        libev-dev \
        libevent-dev \
        libmaxminddb-dev \
        libmemcached-dev \
        libmnl-dev \
        libunistring-dev \
        libwebsockets-dev \
        libxml2-dev \
        linux-headers \
        lksctp-tools-dev \
        lua-dev \
        mariadb-dev \
        mongo-c-driver-dev \
        ncurses-dev \
        net-snmp-dev \
        openldap-dev \
        pcre2-dev \
        perl-dev \
        postgresql-dev \
        python3-dev \
        rabbitmq-c-dev \
        ruby-dev \
        sqlite-dev \
        unixodbc-dev \
        wireshark-common \
    && adduser -D build && addgroup build abuild \
    && echo "%abuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/abuild
RUN git clone https://github.com/lyatanski/kamailio.git
RUN cmake -S /kamailio -B /out -D CMAKE_BUILD_TYPE=Release -D MODULE_GROUP_NAME="DEFAULT KIMS KREDIS KPRESENCE" \
    && cmake --build /out --target install -j 6

FROM alpine:latest
RUN apk add libxml2
COPY --from=build /usr/local/sbin/kamailio /sbin/
COPY --from=build /usr/local/lib/kamailio/modules/xhttp.so \
    /usr/local/lib/kamailio/modules/xhttp_prom.so \
    /usr/local/lib/kamailio/modules/pua.so \
    /usr/local/lib/kamailio/modules/cdp.so \
    /usr/local/lib/kamailio/modules/cdp_avp.so \
    /usr/local/lib/kamailio/modules/db_redis.so \
    /usr/local/lib/kamailio/modules/debugger.so \
    /usr/local/lib/kamailio/modules/ims_auth.so \
    /usr/local/lib/kamailio/modules/ims_charging.so \
    /usr/local/lib/kamailio/modules/ims_dialog.so \
    /usr/local/lib/kamailio/modules/ims_icscf.so \
    /usr/local/lib/kamailio/modules/ims_ipsec_pcscf.so \
    /usr/local/lib/kamailio/modules/ims_isc.so \
    /usr/local/lib/kamailio/modules/ims_qos.so \
    /usr/local/lib/kamailio/modules/ims_registrar_pcscf.so \
    /usr/local/lib/kamailio/modules/ims_registrar_scscf.so \
    /usr/local/lib/kamailio/modules/ims_usrloc_pcscf.so \
    /usr/local/lib/kamailio/modules/ims_usrloc_scscf.so \
    /usr/local/lib/kamailio/modules/kex.so \
    /usr/local/lib/kamailio/modules/presence.so \
    /usr/local/lib/kamailio/modules/pv.so \
    /usr/local/lib/kamailio/modules/rr.so \
    /usr/local/lib/kamailio/modules/siputils.so \
    /usr/local/lib/kamailio/modules/sl.so \
    /usr/local/lib/kamailio/modules/textops.so \
    /usr/local/lib/kamailio/modules/tm.so \
    /usr/local/lib/kamailio/modules/xlog.so /usr/local/lib/kamailio/modules/
COPY cscf /etc/ims

ENTRYPOINT ["sh", "-c", "kamailio -DD -E -f /etc/ims/$CSCF.cfg"]
