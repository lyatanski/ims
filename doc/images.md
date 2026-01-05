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
At the time of writing, there are 2 main versions maintained:
- master, aka. the current stable version
- 1.0, aka. development branch.
There are prebuilt images documented in the [official installation guide](https://cgrates.readthedocs.io/en/latest/installation.html#pull-docker-images):
```
dkr.cgrates.org/master/cgr-engine
dkr.cgrates.org/master/cgr-loader
dkr.cgrates.org/master/cgr-migrator
dkr.cgrates.org/master/cgr-console
dkr.cgrates.org/master/cgr-tester
```
If version `1.0` provides more convenient solution, custom build should be utilized.

## Test
Multiple technologies need to be utilized for the test image:
- [Doubange](https://github.com/lyatanski/doubango) for SIP and RTP implementation
- GTPv2 implementation. Convinient solution is to use [go-gtp](https://github.com/wmnsk/go-gtp)
- GTP-U implementation. There are miltiple approaches but probably the Linux kernel module is one simple approach to implement. However this approach has limitation in dedicated bearer implementation which could be problematic. Alternative solution could be utilizing `tun` device and routing the traffic to it. Probably eBPF solution should be considered as it could transparently wrap the IP frames and provide better performance than `tun` device.
