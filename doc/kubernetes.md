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

### Network attachment (implemented)

The first of the three is what the chart implements: `gm.enabled` in
`charts/ims/values.yaml` attaches a Multus `NetworkAttachmentDefinition` to the
P-CSCF pod and moves Gm onto it.

**It is on by default**, along with the network on rtpengine's `internal`
interface below, and enabling it is what creates it: the chart owns the NAD
rather than expecting the cluster to carry one, so the pod is never annotated
for a network that does not exist. What the cluster still has to supply is
Multus itself — without the CRD the install fails on an unknown kind — and a
node device for `config.master` to sit on, which is the one field the chart
cannot guess. `charts/ims/values-ci.yaml` is the single-node answer to both: it
keeps the attachments on and swaps `config` for a `bridge` with host-local
addressing, which is what the CI job and `kind.sh` install with. `./kind.sh
prepare` is what puts Multus on the cluster for either.

```yaml
gm:
  enabled: true         # renders the NAD and attaches it
  name: gm              # created as <release>-gm; also what the annotation references
  interface: gm0        # pinned, which is why the annotation is the JSON form
  config:
    master: eth0        # the node's device -- set this first
```

The one thing that is not a chart setting is the address. `ipsec_listen_addr`
is what the protected ports bind to and what the kernel SAs and xfrm policies
are keyed on, and `ims_ipsec_pcscf` parses it with `str2ipbuf()`
(`ims_ipsec_pcscf_mod.c:226`): a numeric IPv4 literal, never an interface name,
and `mod_init` returns -1 for anything else. With Gm on a secondary interface
the address comes from that network's IPAM at pod creation, so it is in no
field Kubernetes can project and in no value Helm can render. The chart
therefore passes `GMDEV` instead, and `images/kamailio/cscf/start.sh` — now the
image's entrypoint — reads the address off that device and exports `IPSEC` from
it before exec'ing kamailio. Without the attachment nothing changes: the chart
still sets `IPSEC` from `status.podIP` and the shim passes it straight through.

Two things do not follow automatically:

- **The PCO.** What the UE dials is the P-CSCF list the SMF hands out, and the
  core chart fills it from the P-CSCF's headless Service, which publishes pod
  addresses — Kubernetes Endpoints carry the primary CNI's address and nothing
  else. Set `ims.pcscf` in `charts/core/values.yaml` to the Gm addresses, one
  per P-CSCF, or the UE keeps registering over the interface this was meant to
  replace. Empty, it falls back to the Service name. Nothing checks it: pointed
  at the wrong interface, registration still works, so the only symptom is that
  the DNAT-free path is silently unused.
- **The route to the UE pool.** The `ueroute` sidecar derives its next hop from
  the pod's default route, which still points at the primary CNI. When the pool
  is reached through the Gm network's router instead, name it in
  `global.ue.via`.
- **Masquerade on the way in.** Whatever forwards the UE's packets to the Gm
  address must not SNAT them. A cluster that masquerades traffic leaving the pod
  CIDR will rewrite the source of a packet the UPF forwards to a Gm address that
  is outside it, and ESP in transport mode does not survive that -- which is the
  very thing the attachment exists to avoid. It fails *late* and looks like
  something else: the plain REGISTER and the 401 both ride through, because UDP
  survives NAT, and only the protected REGISTER disappears. The tell is in the
  P-CSCF's own log,

  ```
  ipsec_create(): Registration for contact with AOR [sip:10.10.0.2:5088],
      VIA [1://10.10.0.2:5088], received_host [1://10.20.0.1:5088]
  ```

  where `received_host` is the router's address rather than the UE's. Seen on
  KinD, whose kindnet installs `KIND-MASQ-AGENT` with a single `RETURN` for the
  pod CIDR and `MASQUERADE` for everything else; exempt the Gm subnet there.
- **Asymmetry on the way out**, which is what `mhomed = 1` in `proxy.cfg` is
  for. kamailio relays from the socket a message arrived on, and for anything
  the UE sent that is now the protected socket bound to the Gm address — so the
  REGISTER going on to the I-CSCF leaves by the Mw interface carrying a Gm
  source address. Strict reverse-path filtering drops it. The symptom is
  indistinguishable from a broken core: the UE gets its 401, installs its SAs,
  sends the protected REGISTER, and nothing answers. `mhomed` makes kamailio
  pick the source by looking up the route to the destination instead. Measured
  on KinD with the node at `rp_filter=1` — without it, 0/2 registered and
  `TcpExtIPReversePathFilter` moved by 10 per run; with it, 2/2 registered over
  ESP, a call answered, and the counter did not move.

The reservation in the first bullet of the list above still stands. whereabouts
hands out the next free address in the range, not the one the departing pod
had, so an ordinal does not keep its Gm address across rescheduling — this is
the prerequisite for HA-PLAN Tier 1's takeover, not the whole of it.



## Serving-CSCF
S-CSCF to PSTN connectivity. When S-CSCF is sending packet it will be sent by default from the worker node host IP. When receiving response on the same IP, Service type NodePort on the 5060 port is required. This is a problem as this requires system k8s reconfiguration as the port is not allowed by default for this Service type allocation.


## rtpengine
The same challenges as the Proxy-CSCF apply. [whereabouts](https://github.com/k8snetworkplumbingwg/whereabouts) with host device/macvlan could be utilised as the IP in the SDP is assigned by the rtpengine when offer/answer is forwarded to it. IP allocation pool could be used for these cases.

### Network attachment (implemented)

Each entry in `media.interfaces` in `charts/rtpengine/values.yaml` can carry a
`network`, and the one on `internal` is on by default for the same reason as
Gm, with the same ownership: enabling it renders the NAD named by
`network.name`, so no two interfaces may share one. It needs no shim: rtpengine resolves a device name to an address itself, so
the device the attachment creates goes straight into the interface's `address`.

```
Could not parse 'media0' as network address, checking to see if it's an interface
Determined address 10.30.0.5 for interface 'media0'
```

Only media moves. The ng control socket stays on `0.0.0.0` behind the ClusterIP
Service the S-CSCF addresses, which is the one part of rtpengine that wants
Kubernetes load balancing. Without an attachment the interface binds whatever
its `address` names on the pod itself — `any` being every address it has, which
under Kubernetes is the pod address.

The same reservation as for Gm applies: an address out of a whereabouts pool is
reachable from the UE, but it is not one the ordinal keeps across rescheduling,
which is what HA-PLAN §5.5 needs before media can follow a takeover.

The one thing that is not optional is the **return route**, which is why the
shipped `config` carries an `ipam.routes` entry for the UE pool. rtpengine
answers with its media address, but nothing else in the pod routes the UE pool
out of the media interface, so the RTP would leave by the primary one still
carrying the media source address — dropped by strict reverse-path filtering,
and the call then comes up *answered* with the audio missing rather than
failing. Measured on KinD: without the route the node's
`TcpExtIPReversePathFilter` moved by ~179 over one two-stream call and neither
stream received anything; with it, the best run was 199 sent / 198 received at
0% loss and MOS 4.40. It goes in the attachment rather than a sidecar because
the CNI installs it at attach time and the rtpengine image has no `ip`. Its
`dst` has to track `global.ue.subnet` by hand.

Do not read those figures as a verdict on the media path as a whole. The same
two-subscriber call with **both attachments off** measured 199 sent / 0
received with both streams dead, and some attachment-on runs still lost one of
the two streams. Whatever that is, it predates this work and is worse without
it; it wants isolating separately.

### More than one interface, and who chooses (implemented)

`media.interfaces` is a list because a call between two UEs and a call out to
the trunk are not answered with the same address. rtpengine calls these
*logical interfaces*, renders them as `[interface-<name>]` sections, and picks
one per side of a call from `direction=`.

Naming them at every `rtpengine_manage()` in the S-CSCF would put media policy
in the dial plan, so the chart puts it in `templates` instead — rtpengine's own
`[templates]` section, a name for a string of ng flags. The S-CSCF then sends
only the name:

| call | template | interfaces (offerer → answerer) |
| --- | --- | --- |
| UE to UE | `internal` | internal → internal |
| UE to the trunk | `outgoing` | internal → external |
| trunk to a UE | `incoming` | external → internal |

`images/kamailio/cscf/serving.cfg` chooses in `route[E164]`, which is where the
breakout decision is already made, and hands the name over in `route[MORIG]`.
An incoming call is anchored on its terminating leg instead, and only where a
trunk is configured — see `route[MTERM]` for why anchoring an on-net call there
as well would loop its media back on itself.

Measured against the daemon (26.3) with a rendered config, one advertised
address on `external` to make the choice visible:

```
template=internal   toward callee: 172.17.0.3:30006    toward caller: 172.17.0.3:30016
template=outgoing   toward callee: 203.0.113.7:40016   toward caller: 172.17.0.3:30060
template=incoming   toward callee: 172.17.0.3:30062    toward caller: 203.0.113.7:40078
```

with the ports also coming from each interface's own range. Two things worth
knowing about how it fails: rtpengine takes a `direction=` naming an interface
it has never heard of, logs `Templates for signalling flags '...' not found`
and answers on its **default** interface — a call that connects with the media
on the wrong network. That is why the chart validates the templates against
`media.interfaces` at render time and refuses rather than installs. And an
interface with no attachment still resolves, so a single-network cluster can
leave `external` as an `alias` of `internal` and lose nothing but the second
address.


