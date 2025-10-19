# Tracing

There are multiple approaches for tracing the IMS flows:

## [tcpdump](https://www.tcpdump.org/)
Probably the best capturing approach as it captures everything on the network. The drawback is that there need to be one tcpdump per container we need to trace. The alternative for single tcpdump is only available to compose setup and the capture size could be prohibitively large. This brings complexity and overhead to compose setup. In Kubernetes it could be slightly simpler with sidecar container. Bigger problem could pose when there is need to combine all the captures to trace single call flow.A also there is no trivial way to observe it directly in the setup live.

## [siptrace](https://kamailio.org/docs/modules/devel/modules/siptrace.html) Kamailio module
Can it trace diameter? Also DNS and tcp 3-way handshake could be useful in troubleshooting some problems.  the benefit lie# in storage alternatives and HEP capable servers integration ([Homer](https://github.com/sipcapture/homer) for example)

## [captagent](https://github.com/sipcapture/captagent)
Again HEP compatible and respective could be integrated with Homer. Kind of middle ground. Still requires one additional container per observed container. Seems to have at least sip and diameter capabilities.
