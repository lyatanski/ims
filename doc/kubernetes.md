# Kubernetes

## Common Challenges
Determination of when instance has calls running on it. This is necessary to know when it is safe to terminate instance.


## Proxy-CSCF
Gm requires IPsec. In Kamailio this functionality is implemented in the ims_ipsec_pcscf module. This module only support transport mode IPsec which does not tolerate NAT. In Kubernetes with service based exposure, there is DNAT. 3GPP TS 24.229 (Annex F) allows for NAT detection by comparing the top-most SIP Via header with the IP level address information from where the request was received. If NAT is detected and UE supports UDP encapsulated tunnel mode as per RFC 3948, it should be used in this case. The problem lies in that some UEs do not support tunnel mode IPsec (advertised in SIP Security-Client header, mod as per TS 33.203 Annex H). Available approaches in this situation are:
- host device/macvlan attached to the pod. Kubernetes NAT is skipped and connectivity is directly with the pod. Not ideal when considering High Availability because only single instance withs limitation comes from the fact only single IP is provided to the UE in the PCO. Strategy in this case is limited to "Recreate".
- moving the IPsec endpoint to the IPVS. The Kubernetes service implementation in modern clusters is based on IPVS/LVS. These virtual devices could be used as IPsec termination and the SIP packet to be forwarded internally. Source Hashing (sh) load balancing algorithm should be used so the same UE will go to the same Proxy instance. This could work until the conntrack for UDP expires. MT INVITE might be a problem. In such situations the message might be routed with the worker node IP instead of service IP and will not be IPsec encapsulated.
- eBPF? Custom eBPF load balancer could be implemented and it could forward towards multiple pods. Cilium does this but as CNI project, it is situated with knowledge of the pod network interface and could forward directly towards it. Another issue will be how to handle the IPsec? The eBPF program should be situated in such manner to be able to handle both incoming and outgoing packets. XDP seems to out of the question, probably TC.


## Serving-CSCF
S-CSCF to PSTN connectivity. When S-CSCF is sending packet it will be sent by default from the worker node host IP. When receiving response on the same IP, Service type NodePort on the 5060 port is required. This is a problem as this requires system k8s reconfiguration as the port is not allowed by default for this Service type allocation.


## rtpengine
The same challenges as the Proxy-CSCF apply. [whereabouts](https://github.com/k8snetworkplumbingwg/whereabouts) with host device/macvlan could be utilised as the IP in the SDP is assigned by the rtpengine when offer/answer is forwarded to it. IP allocation pool could be used for these cases.


