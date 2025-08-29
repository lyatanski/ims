# General

Image selection is pretty important for optimizing starup times and performance.
Smaller options (Alpine based or distroless) should be preferred.


## [Kamailio](https://github.com/kamailio/kamailio) (P-CSCF/I-CSCF/S-CSCF)
Kamailio already has latest and greatest (master) built into minimal container:
`ghcr.io/kamailio/kamailio-ci:master-alpine`. This is all fine and dandy, until we stumble upon missing module for P-CSCF IPsec. Why this particular module is missing, when the rest of the IMS modules are present? Bug?

Nevertheless, we can build our own image, installing Kamailio alpine packages.


## [CoreDNS](https://coredns.io)
Benefits of using this particular DNS include:
- Kubernetes default choice, so in K8S deployments the image could already be present on the cluster and no additional download would be required.
- Its configuration is pretty convenient and allows quite the flexibility
The default image on [dockerhub](https://hub.docker.com/r/coredns/coredns) is
already pretty minimal and good choice.


## IMS DB
For IMS to function DB is required. There are multiple options:
### [MariaDB](https://mariadb.org)
Safe choice, but kind of heavy and its performance leaves things to be desired. If  ims_usrloc_scscf DB storage is used, it might be a necessity as there are hardcoded SQL statements in the module implementation.

### [Valkey](https://valkey.io)
This [Redis](https://redis.io) drop-in replacement will be the choice for this
setup due to its small image, small memory footprint, fast performance. The only
drawback is required additional handling in Kamailio for providing "schema".
There is no need for custom image build and the default Alpine based image,
hosted on [dockerhub](https://hub.docker.com/r/valkey/valkey/tags?name=alpine),
will do just fine.


## [rtpengine](https://github.com/sipwise/rtpengine)
Alpine does provide smaller image size and newer releases, but it lacks support for some transcoding.
Debian does not currently provide any benefits over Ubuntu.


## [open5gs](https://github.com/open5gs/open5gs) (HSS/PCRF/PGW)
It seem there are not any prebuild options so build from source will be the
approach. The build will be Alpine based for size reduction. For detailed build
instructions, please check the Dockerfile for its creation.


## [freeDiameter](https://github.com/freeDiameter/freeDiameter) (DRA)
DRA could be built using freeDiameter, like in the example from Nick vs Networking blog.
The image should contain basic freeDiameter daemon build.
[1](https://nickvsnetworking.com/diameter-routing-agents-part-3-building-a-dra-with-freediameter/)
[2](https://nickvsnetworking.com/diameter-routing-agents-part-4-advanced-freediameter-dra-routing/)
[3](https://nickvsnetworking.com/diameter-routing-agents-part-5-avp-transformations/)
[4](https://nickvsnetworking.com/diameter-routing-agents-part-5-avp-transformations-with-freediameter-and-python-in-rt_pyform/)


## [CGRateS](https://github.com/cgrates/cgrates) (billing)
There are some prebuilt images described in the official [documentation](https://cgrates.readthedocs.io/en/latest/installation.html#pull-docker-images)
```
dkr.cgrates.org/master/cgr-engine
dkr.cgrates.org/master/cgr-loader
dkr.cgrates.org/master/cgr-migrator
dkr.cgrates.org/master/cgr-console
dkr.cgrates.org/master/cgr-tester
```
For detailed build instructions, the Dockerfile in this repo could be used.


