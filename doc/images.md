# General

we will prefer alpine or distroless images, where possible, due to their smaller size.

## Kamailio

Kamailio already has latest and greatest (master) built into minimal container:
`ghcr.io/kamailio/kamailio-ci:master-alpine`. This is all fine and dandy, untill we stumble upon missing module for P-CSCF IPsec. Why this particular module is missing, ewhen the rest of the IMS modules are present? Bug?

Nevertheless, we can build our own image, installing Kamailio alpine packages.


