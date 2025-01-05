# General

we will prefer alpine or distroless images, where possible, due to their smaller size.

## [Kamailio](https://github.com/kamailio/kamailio) (P-CSCF/I-CSCF/S-CSCF)

Kamailio already has latest and greatest (master) built into minimal container:
`ghcr.io/kamailio/kamailio-ci:master-alpine`. This is all fine and dandy, untill we stumble upon missing module for P-CSCF IPsec. Why this particular module is missing, ewhen the rest of the IMS modules are present? Bug?

Nevertheless, we can build our own image, installing Kamailio alpine packages.

## [rtpengine](https://github.com/sipwise/rtpengine)
Alpine does provide smaller image size and newer releases, but it lacks support for some transcodings.
Debian does not currently provide any benefits over Ubuntu.

## [open5gs](https://github.com/open5gs/open5gs) (HSS/PCRF/PGW)
build from source on alpine

## [CGRateS](https://github.com/cgrates/cgrates) (billing)
build from source and place in container FROM SCRATCH
