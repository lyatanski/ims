FROM ubuntu:jammy AS build
RUN apt update && apt install -y --no-install-recommends \
git build-essential cmake ninja-build libtool yasm \
ragel \
libsrtp2-dev libssl-dev libopus-dev \
libspeexdsp-dev \
libavutil-dev libswscale-dev libavcodec-dev \
libvpx-dev libyuv-dev libgsm1-dev swig \
python3-dev  python3-pip
RUN git clone --depth=1 https://github.com/lyatanski/doubango.git
RUN cmake -S doubango -B out -G Ninja #-D CMAKE_BUILD_TYPE=Debug
RUN cmake --build out --target install && cp out/_deps/libmnl/usr/lib/libmnl.so* /usr/local/lib/ && ldconfig

FROM golang AS gobld
COPY ./src /go
RUN go build -o gtp

FROM ubuntu:jammy
RUN apt update && apt install --no-install-recommends -y python3-pip
COPY --from=build /out/_deps/libmnl/usr/lib/libmnl.so* /usr/local/lib/
COPY --from=build /out/plugins/ipsec_linux/ipsec.so /usr/lib/
COPY --from=gobld /go/gtp /usr/bin/
COPY ./src/sip.py /opt/
RUN --mount=type=bind,from=build,source=/out/bindings/python/,target=/opt/python,rw ldconfig && pip install /opt/python

