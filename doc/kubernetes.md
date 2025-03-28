# Kubernetes

## Common Challenges
Determination of when instance has calls running on it. This is necessary to know when it is safe to shut down instance.


## Proxy-CSCF Challenges
Gm requires IPsec which does not tolerate NAT and in k8s with service based exposure, there is DNAT. This could be workarounded in multiple ways:
- host device/macvlan attached to the pod. Kubernetes NATing is skipped and connectivity is directly with the pod. Not ideal when considering high availability because of IP allocation. Either static IP should be set for this interface, in which case the application upgrade strategy is limited to "recreating" or dynamic IP could be allocate by [whereabouts](https://github.com/k8snetworkplumbingwg/whereabouts), but this requires reconfiguration in the PGW.
- moving the IPsec endpoint to the IPVS. The k8s service implementation in modern clusters is based on IPVS/LVS. These virtual devices could be used as IPsec termination and the SIP packet to be forwarded internally without encryption. Source Hashing (sh) load balancing algorithm should be used so the same UE will go to the same Proxy instance. This could work until the conntrack for UDP expires and MT INVITE will be a problem. The message will be routed with the worker node IP instead of service IP and will not be IPsec encapsulated.
- eBPF? Should be faster than IPVS and should allow more flexibility. Needs research...


## Serving-CSCF Challenges
S-CSCF to PSTN connectivity. When S-CSCF is sending packet it will be sent by default from the worker node host IP. When receiving response on the same IP, Service type NodePort on the 5060 port is required. This is a problem as this requires system k8s reconfiguration as the port is not allowed by default for this Service type allocation.


## rtpengine Challenges
The same challenges as the Proxy-CSCF apply. [whereabouts](https://github.com/k8snetworkplumbingwg/whereabouts) with host device/macvlan could be much more useful as the IP in the SDP is assigned by the rtpengine when offer/answer is forwarded to it. IP allocation pool could be used for these cases.


