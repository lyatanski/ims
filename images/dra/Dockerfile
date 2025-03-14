FROM alpine

RUN apk add git cmake make g++ bison flex lksctp-tools-dev libidn2-dev gnutls-dev libgcrypt-dev
RUN git clone https://github.com/freeDiameter/freeDiameter.git
RUN cmake -S freeDiameter -B out
RUN cmake --build out

