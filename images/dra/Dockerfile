FROM alpine AS build

RUN apk add git cmake make g++ bison flex lksctp-tools-dev libidn2-dev gnutls-dev libgcrypt-dev
RUN git clone https://github.com/freeDiameter/freeDiameter.git
RUN cmake -S freeDiameter -B out
RUN cmake --build out --target install

FROM alpine
RUN apk add lksctp-tools libidn2 gnutls libgcrypt
COPY --from=build /usr/local/lib/* /usr/local/lib/
COPY --from=build /usr/local/bin/* /usr/local/bin/
ENTRYPOINT ["freeDiameterd", "-c", "/etc/dra.conf"]
