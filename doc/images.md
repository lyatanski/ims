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
Safe choice, but kind of heavy and its performance leaves things to be desired

### [Valkey](https://valkey.io)
This [Redis](https://redis.io) drop-in replacement will be the choice for this
setup die to its small image, small memory footprint, fast performance. The only
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


## [CGRateS](https://github.com/cgrates/cgrates) (billing)
It seem there are not any prebuild options so build from source will be the
approach to be taken. This will allow creation of distroless image with only
the necessary binary in it. For detailed build instructions, please check
the Dockerfile for its creation.


