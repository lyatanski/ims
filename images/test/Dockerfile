FROM ubuntu:jammy AS build
RUN apt update && apt install -y --no-install-recommends \
git build-essential cmake ninja-build libtool yasm  bind9-host \
ragel \
libsrtp2-dev libssl-dev libopus-dev \
libspeexdsp-dev \
libavutil-dev libswscale-dev libavcodec-dev \
libvpx-dev libyuv-dev libgsm1-dev swig \
python3-dev  python3-pip
RUN git clone --depth=1 https://github.com/lyatanski/doubango.git
WORKDIR doubango
RUN cmake -B out -G Ninja #-D CMAKE_BUILD_TYPE=Debug
RUN cmake --build out --target install && cp out/_deps/libmnl/usr/lib/libmnl.so* /usr/local/lib/ && ldconfig

FROM golang AS gobld
COPY ./gtp.go /go
RUN go build -o gtp

FROM ubuntu:jammy
RUN apt update && apt install --no-install-recommends -y python3-pip iproute2 bind9-host
COPY --from=build /doubango/out/_deps/libmnl/usr/lib/libmnl.so* /usr/local/lib/
COPY --from=build /doubango/out/plugins/ipsec_linux/ipsec.so /usr/lib/
COPY --from=gobld /go/gtp /usr/bin/
COPY ./sip.py /opt/
RUN --mount=type=bind,from=build,source=/doubango/out/bindings/python/,target=/opt/python,rw ldconfig && pip install /opt/python

