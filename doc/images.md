# General

Utilizing optimized container images is important for improving startup/pull time,
runtime performance and attack surface. It would be preferable to utilize smaller
images either based on **Alpine** or **distroless**.


## [Kamailio](https://github.com/kamailio/kamailio) (P-CSCF/I-CSCF/S-CSCF)
Kamailio provides relatively minimal container image from the latest master branch:
`ghcr.io/kamailio/kamailio-ci:master-alpine`. Still bespoke image with just the
required modules included could be built. The source approach should be selected
for maximal flexibility.


## [CoreDNS](https://coredns.io)
Benefits of using this particular DNS include:
- It is the default DNS server in Kubernetes, meaning the image may already exist on the cluster during K8S deployments (reducing image pulls).
- The configuration format is clean and flexible, allowing advanced service discovery patterns.
The [official Docker Hub image](https://hub.docker.com/r/coredns/coredns) is already minimal and is a good choice.


## IMS DB
Database is not strictly mandatory for IMS to function. Nevertheless, it could
improve service recory in case of restarts. The main options are:
### [MariaDB](https://mariadb.org)
Currently some for of relational database is required when ims_usrloc_scscf DB
storage is used due to hardcoded SQL statements in the module implementation.
The most tested approach is to deploy MySQL/MariaDB. This database is not ideal
choice, however, as is resource heavy and is not exactly cloud native solution.

### [Valkey](https://valkey.io)
[Redis](https://redis.io) drop-in replacement will be preferred solution due to:
- necessary for the [rtpengine](https://github.com/sipwise/rtpengine) high availability.
- small image size
- small memory footprint
- fast performance
[Kamailio](https://github.com/kamailio/kamailio) requires additional handling in its configuration in the form of providing "schema".
No custom build is required as there is already [official Alpine-based image](https://hub.docker.com/r/valkey/valkey/tags?name=alpine).


## [rtpengine](https://github.com/sipwise/rtpengine)
Provides media relay functionality to the setup.

Installation from the package management repository should be avoided.
On Alpine it lacks some transcoding functionality.
On Ubuntu based system the version could be quite old and lack convenient features.

Build from source ashould be preferred approach.


## [open5gs](https://github.com/open5gs/open5gs) (HSS/PCRF/PGW)
There do not appear to be suitable prebuilt images for this use case, so the optimal approach would be to build from source.


## [freeDiameter](https://github.com/freeDiameter/freeDiameter) (DRA)
DRA could be built using freeDiameter, like in the example from Nick vs Networking blog.
The image should contain basic freeDiameter daemon build.
[1](https://nickvsnetworking.com/diameter-routing-agents-part-3-building-a-dra-with-freediameter/)
[2](https://nickvsnetworking.com/diameter-routing-agents-part-4-advanced-freediameter-dra-routing/)
[3](https://nickvsnetworking.com/diameter-routing-agents-part-5-avp-transformations/)
[4](https://nickvsnetworking.com/diameter-routing-agents-part-5-avp-transformations-with-freediameter-and-python-in-rt_pyform/)


## [CGRateS](https://github.com/cgrates/cgrates) (billing)
At the time of writing, there are 3 main versions maintained:
- v0.10, aka. stable (old, missing years of fixes and features)
- master (v0.11.0~dev), aka. development — recommended; this is what upstream
  builds nightly packages from and what this project builds
- 1.0, aka. experimental (rewritten AccountS/RateS/ActionS subsystems with a
  different configuration and API surface)

The engine exposes its JSON-RPC API over plain HTTP (`listen.http`, path
`/jsonrpc`), so provisioning only needs an HTTP client — see the `preload`
service in billing.yml and cgr-tester.sh.
There are prebuilt images documented in the [official installation guide](https://cgrates.readthedocs.io/en/latest/installation.html#pull-docker-images):
```
dkr.cgrates.org/master/cgr-engine
dkr.cgrates.org/master/cgr-loader
dkr.cgrates.org/master/cgr-migrator
dkr.cgrates.org/master/cgr-console
dkr.cgrates.org/master/cgr-tester
```

engine - contains all the microservices
- DiameterAgent: translates Diameter message AVPs to internal API call fields;
- SessionS: gateway between the Agent and rest of CGRateS subsystems;
- ChargerS: decide the number of billing runs for customer/supplier charging;
- AttributeS: populate extra data to requests (ie: prepaid/postpaid, passwords, paypal account, LCR profile);
- RALs: calculate costs as well as account bundle management;
- SupplierS: selection of suppliers for each session (in case of OpenSIPS, it will work in tandem with their DRouting module);
- StatS: computing statistics in real-time regarding sessions and their charging;
- ThresholdS: monitoring and reacting to events coming from above subsystems;
- EEs: exporting rated CDRs from CGR StorDB (export path: /tmp).
loader - used for initial bootstraf for user data/profiles from CSV files
console - CLI for interacting with the oengine
migrator - used for database migration
tester - load testing

[Documentation](https://cgrates.readthedocs.io/en/latest/index.html0
[Support](https://groups.google.com/g/cgrates)
[Source](https://github.com/cgrates/cgrates)

## Test
The image is [pro2call](https://github.com/lyatanski/pro2call)'s
`bindings/examples/ims_test_s5.lua` — one process that is the SGW, the UEs and
the far end at once, driving every layer the stack under test exposes:

- GTPv2-C over S5/S8, one Create Session per subscriber, and the Delete Session
  that tears it down.
- GTP-U as an eBPF datapath attached to the container's interface, with a TFT
  per flow keyed on the UE's own address. Real G-PDUs on the wire, so dedicated
  bearers and per-UE filters are expressible — which the kernel `gtp0` device
  the earlier Go implementation used is not, and a `tun` device only is at the
  cost of a copy per packet.
- SIP registration with IMS-AKA: the AUTN verified and CK/IK derived from
  Milenage, four transport-mode ESP SAs installed through XFRM, and the
  authenticated REGISTER sent over them.
- Calls between the registered subscribers, both ends in the same process on
  one monotonic clock — so setup time decomposes into true one-way segments
  (post-dial delay, transit each direction, cut-through, release) instead of
  half a round trip, reported as p50/p95/p99/max.
- RTP on a sample of the calls, with loss/jitter from the receive stats, the
  peer's view of the uplink from the RTCP report blocks, and a G.107 MOS
  estimate off those counters (packet statistics only — not PESQ/POLQA).
- SMS over IMS (`IMS_SMS=1`), the TPDU/RP layers in a `MESSAGE` body, round
  tripped against the sent text byte for byte.

Everything above is the pro2call libraries: SIP, SDP, SMS, Diameter, RTP,
GTP and XFRM as C with SWIG/Lua bindings, so the whole load generator is one
event loop and no per-subscriber thread or process. That is what makes the
subscriber count a knob rather than a rewrite — and why the numbers it prints
are the stack's rather than the tool's.

The image builds the tree from source and bakes it, so a run is reproducible;
`--build-arg PRO2CALL_REF=<sha>` pins it, which is the difference between a
performance baseline and an anecdote. Its default `CMD` is the script above,
but the whole `bindings/examples` directory is on board — `cx_hss.lua`,
`ipsmgw.lua` and `smsc_stub.lua` stand in for the network around the part
being measured.
