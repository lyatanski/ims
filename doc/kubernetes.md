# Kubernetes

Two charts, installed in either order. `ims` is the IMS core plus CoreDNS,
rtpengine and the state store; `core` is the EPC — HSS, PCRF and the PGW
control/user plane split — plus MongoDB and a subscriber seed.

    kind create cluster
    helm install core charts/core
    helm install ims  charts/ims --wait

`--wait` belongs on whichever goes in second, and there is only one of the two it
can usefully sit on. A CSCF is Ready when `cdp_has_app(...)` says its Diameter
peer is established, so waiting for `ims` waits for Cx and Rx — which proves the
HSS and PCRF are *serving*, not merely running. Waiting for `core` proves much
less: an open5gs daemon answers /metrics, and is therefore Ready, the moment it
starts.

That asymmetry matters because the dependency runs both ways and only one
direction is self-healing:

- **IMS needs the EPC**, and retries until it has it. cdp reconnects on Tc,
  which is 30 seconds unless `diameter.xml` says otherwise, so a CSCF started
  against a missing HSS peers on its own — just not instantly. Offer traffic
  inside that window and the I-CSCF answers a REGISTER from a Cx it does not
  have: `480 Temporarily Unavailable - Diameter Cx interface failed`, 0 of N
  registered, every pod Running. The Services publish not-ready addresses
  deliberately, so readiness does not hold that traffic back — waiting does.

- **The EPC needs the P-CSCF's name**, once, and never retries. open5gs resolves
  `smf.p-cscf` while parsing its configuration and keeps the addresses; a miss is
  logged and skipped, leaving `smfd` Ready with no P-CSCF to put in the PCO. The
  UE attaches and has nowhere to send REGISTER, and nothing anywhere restarts.
  So `smfd` is held in an init container until the name resolves, which is what
  makes the order above safe — and what makes the reverse order safe too.

Nothing has to be passed in. The CoreDNS address the CSCFs resolve against is
derived from the cluster's own service CIDR, and both charts default to the same
PLMN, realms and USIM as [.env](.env) — so `core` seeds a subscriber the `ims`
test can actually authenticate.

The release names matter: Cx and Rx cross between the two, and each chart names
the other's Services through `global.core.release` / `ims.release`. Install under
different names and set those to match.

To check the installation:

    helm test ims --logs

which attaches `test.subscribers` UEs over S5/S8, registers each with IMS-AKA and
transport-mode ESP, and calls them pairwise — the same load generator the compose
`test` profile runs. Raise `test.subscribers` to put the chain under load.

`helm test` needs the GTP-U datapath in the test image, which is where the UE's
user plane comes from. To check the signalling chain on its own — Gm through Cx
to the HSS and back — an unprotected REGISTER sent straight at the P-CSCF should
come back as a `401` from the S-CSCF carrying an `AKAv1-MD5` challenge and a
`Security-Server` header.


## The UE pool

`session.subnet` is not part of the cluster's pod CIDR, so nothing in the
cluster knows where it lives. Three pieces put it on the map, each covering a
different way the user plane dies without them:

- **`session.dev`, addressed and up.** open5gs opens the TUN device it
  decapsulates onto and stops there — no address, link DOWN — so the kernel
  drops everything `upfd` writes to it: `ogs_write() failed (5:I/O error)` in
  the log, and rx 0 with the drop counter climbing in `/proc/net/dev`. A sidecar
  in the UPF pod configures it, the job compose gives `upftun`.

- **A route for the pool on every node**, from the `core-route` DaemonSet. It
  covers both directions at once. The uplink otherwise dies at the node's strict
  `rp_filter` — a packet from an address it cannot route back to, counted as
  `TcpExtIPReversePathFilter` in `nstat` — so a REGISTER never reaches the
  P-CSCF; the downlink dies for want of a route, since a P-CSCF answering a UE
  hands the response to its default gateway, which is the node. The route is
  `onlink`, and that is not decoration: under a CNI that gives each pod a
  point-to-point veth — `ptp`, which is what kindnet uses — the node holds a
  `scope host` route per pod address, and a gateway resolved through one of
  those is folded away. The kernel keeps the device, drops the nexthop, and ARPs
  for the *UE* address on the UPF's veth, which nothing answers.

- **An MTU on the P-CSCF's route to the pool.** The UPF adds 36 bytes of GTP-U;
  a response that no longer fits is fragmented, and a fragment carries no GTP
  header for anything downstream to classify, so both halves are lost. Capping
  the route makes the P-CSCF fragment the inner packet first, before the tunnel,
  where each fragment is its own G-PDU. It shows up on exactly the messages that
  matter — the reg-event NOTIFY and a terminating INVITE go missing while the
  786-byte REGISTER 200 OK on the same SA arrives.

All three are reconcile loops rather than one-shots: the TUN device is recreated
whenever `upfd` restarts, and the node route is derived from the UPF pod
address, which moves when the pod is rescheduled.

Moving the UPF costs more than the route, though. open5gs resolves its peers
once, at startup, so a rescheduled UPF also strands the SMF on the address that
is gone — `Retry association with peer failed`, and a Create Session Response
that names a PGW-U which no longer exists. Restart the SMF after moving it.


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


