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

### IPv6

`session.subnet6` is the IPv6 pool beside it, on by default: a UE asking for an
IPv6 or IPv4v6 PDN gets a /64 of it, and the UPF routes the downlink by that
/64. Its traffic takes the IPv4 pool's path, so each of the pieces above has an
IPv6 half, and the cluster has to be dual-stack for them to have anything to
work with:

- the TUN sidecar adds `session.gateway6`, and an init container turns on IPv6
  forwarding in the UPF's namespace. A new namespace inherits the node's IPv4
  settings, `ip_forward` included, but starts IPv6 from the kernel defaults --
  forwarding off -- and `net.ipv6.conf.*` is outside Kubernetes' safe sysctls,
  so it cannot be a pod sysctl without the kubelet's allowlist;
- the node route resolves the UPF through `core-upf-node`, a headless
  `PreferDualStack` Service of its own. The component Services stay
  single-stack on purpose: open5gs resolves `gtpu.server.advertise` with
  `AF_UNSPEC`, and a dual-stack `-gtpu` would put an IPv6 address in every
  F-TEID;
- the P-CSCF's `ueroute` sidecar routes `global.ue.subnet6`, through
  `global.ue.via6` when the pool is reached over Gm's router.

The P-CSCF registers those UEs on an IPv6 Gm address, `gm.addresses6`, entry
*i* being the second address of the P-CSCF `gm.addresses` entry *i* names. It
becomes `IPSEC6`, which `ims_ipsec_pcscf` binds its protected ports on, and
goes into `ims.pcscf` beside the IPv4 one -- the SMF sorts the list into the
PCO's IPv4 and IPv6 containers. With it set, the P-CSCF's IPsec port pool
halves: every port is bound once per family, and the socket budget is what
`ipsec_max_connections` in `cscf/proxy.cfg` explains.

```yaml
gm:
  addresses:
  - 10.20.0.10/24
  addresses6:
  - fd20::10/64
global:
  ue:
    via6: fd20::1
```

`test.pdnType` (`ipv4`, `ipv6`, `ipv4v6`) is what the helm test's UE asks for.
`./kind.sh` makes the cluster dual-stack (`IP_FAMILY`), gives Gm and media an
IPv6 subnet each, exempts both from kindnet's IPv6 masquerade too, and takes
`PDN_TYPE` and `PRO2CALL` for the test.


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
cannot guess. The CI job's values (the `Install IMS` step of
`.github/workflows/charts.yml`, which `kind.sh` repeats) are the single-node
answer to both: they keep the attachments on and swap `config` for a `bridge`
with host-local addressing for media. `./kind.sh
prepare` is what puts Multus on the cluster for either.

```yaml
gm:
  enabled: true         # renders <release>-gm and attaches it
  interface: gm0        # pinned, which is why the annotation is the JSON form
  config:
    master: eth0        # the node's device -- set this first
```

The address is a chart setting. `ipsec_listen_addr` is what the protected
ports bind to and what the kernel SAs and xfrm policies are keyed on, and
`ims_ipsec_pcscf` parses it with `str2ipbuf()` (`ims_ipsec_pcscf_mod.c:226`): a
numeric IPv4 literal, never an interface name, and `mod_init` returns -1 for
anything else. So the address cannot come from an IPAM pool, which assigns it
at pod creation where no value Helm renders can see it. `gm.addresses` lists
them instead, and the chart renders one single-replica StatefulSet per entry,
`<release>-pcscf-<index>`, whose networks annotation names that address in
`ips` and whose `IPSEC` is the same address. The NAD's `static` IPAM with the
`ips` capability is what makes the annotation's address the interface's.

```yaml
gm:
  addresses:            # one P-CSCF each; the prefix length is required
  - 10.20.0.10/24
  - 10.20.0.11/24
```

Scaling is adding an entry, not `replicaCount`, which the P-CSCF ignores while
Gm is attached. The pods are `<release>-pcscf-<index>-0`, but the Diameter
identity stays `<release>-pcscf-<index>`: that is the name the PCRF's
`ConnectPeer` list in the core chart enumerates up to `ims.replicas`, and a
P-CSCF outside it never gets Rx, which surfaces as a call whose 200 OK never
reaches the caller. Nothing allocates or tracks these addresses, so keep them out of
any other pool on the subnet. Without the attachment the P-CSCF is one
StatefulSet of `replicaCount` again and `IPSEC` is `status.podIP`.

Two things do not follow automatically:

- **The PCO.** What the UE dials is the P-CSCF list the SMF hands out, and the
  core chart fills it from the P-CSCF's headless Service, which publishes pod
  addresses — Kubernetes Endpoints carry the primary CNI's address and nothing
  else. Set `ims.pcscf` in `charts/core/values.yaml` to the Gm addresses, one
  per P-CSCF, or the UE keeps registering over the interface this was meant to
  replace — the same list as `gm.addresses`, without the prefix lengths.
  Empty, it falls back to the Service name. Nothing checks it: pointed
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

Each P-CSCF keeps its Gm address across restarts and rescheduling, since the
address belongs to its StatefulSet rather than to a pool. That is the
prerequisite for HA-PLAN Tier 1's takeover, not the whole of it.



## Serving-CSCF
S-CSCF to PSTN connectivity. When S-CSCF is sending packet it will be sent by default from the worker node host IP. When receiving response on the same IP, Service type NodePort on the 5060 port is required. This is a problem as this requires system k8s reconfiguration as the port is not allowed by default for this Service type allocation.


## IBCF

`cscf.border` (off by default) runs `images/kamailio/cscf/border.cfg`, the
entry and exit point on Ici, with rtpengine as its TrGW:

- **Ici** is an attachment of its own, `ici` in the values, the Gm pattern
  again: one single-replica StatefulSet per `ici.addresses` entry,
  `<release>-ibcf-<i>`. The cfg binds the address by value, and it is the one
  the peers' configuration names, so each pod has to know it at start.
  `ICINET` is that address with its prefix, which is how the IBCF tells
  sources on Ici from the rest (metrics, rtpengine's teardown RPC).
- **Mx** is the pod network: the Service `<release>-ibcf` is what
  `ibcf.ims.<realm>` resolves to (the CoreDNS SRV template has to list
  `ibcf`, or the name falls through to the I-CSCF). With the IBCF on, the
  S-CSCF gets `IBCF`, and `TRUNK` too unless `trunk` names another.
- **Peers** are `cscf.border.peers`, rendered as dispatcher's `peers.list`
  (one set each, `entry` order as priority) and `ROUTES`. Ready means the
  first set loaded. The topology hiding key is a Secret, generated once and
  kept across upgrades.
- **The TrGW** is rtpengine's `external` interface, which has to be where the
  peers can reach it: on Ici, through an attachment of its own to the same
  network (`bridge`/`master`), with an IPAM range clear of the IBCF and peer
  addresses. The IBCF reaches the ng socket the way any client does, Service
  or control VIPs, and `b2bUrl` points rtpengine's media timeout back at the
  IBCF (`dlg.terminate_dlg`).

`test.border` is a helm test of its own: pro2call's `ibcf_peer.lua`, the
check `border.sh` runs under compose, as the peer on Ici and an S-CSCF on the
pod network. It needs a pro2call that carries the script, the published one
does not yet, so `kind.sh` runs it only when `$PRO2CALL` has it and CI leaves
it off. In KinD two things are test plumbing rather than the chart: the
rtpengine Ici attachment's `isGateway`, which gives the node an address on
the Ici bridge so the stand-in S-CSCF on the pod network can reach Ici at
all, and a loose `rp_filter` on the node, as the IBCF and the TrGW answer it
from their Ici and media addresses over their pods' eth0.

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

Only media moves. Without `vips` (below) the ng control socket stays on
`0.0.0.0` behind the ClusterIP Service its client addresses. Without an attachment the interface binds whatever
its `address` names on the pod itself — `any` being every address it has, which
under Kubernetes is the pod address.

Unlike Gm, an address out of a whereabouts pool is reachable from the UE but
is not one the ordinal keeps across rescheduling, which is what HA-PLAN §5.5
needs before media can follow a takeover. `vips` is that address — see
[Per-owner addresses](#per-owner-addresses-implemented).

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
*logical interfaces*, renders them as `[interface-<i>-<name>]` sections (one set per replica), and picks
one per side of a call from `direction=`.

Naming them at every `rtpengine_manage()` would put media policy in the
routing script, so the chart puts it in `templates` instead — rtpengine's own
`[templates-<i>]` section, a name for a string of ng flags. The client then
sends only the name:

| offer | template | interfaces (offerer → answerer) |
| --- | --- | --- |
| both legs inside | `internal` | internal → internal |
| from inside, on its way out | `outgoing` | internal → external |
| from outside, on its way in | `incoming` | external → internal |

The client is the IBCF, rtpengine being its TrGW (TS 23.228 Annex I): it names
the template on a call's initial offer by the side the offer came from
(`images/kamailio/cscf/border.cfg`, `route[ENTRY]` and `route[EXIT]`). The
S-CSCF anchored every call here until it was moved, which put the TrGW in the
wrong place and on-net media through a relay it does not need. With
`cscf.border` off nothing in the chart sends rtpengine a call; see
[IBCF](#ibcf) for what `external` has to be for it.

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



### Standby copy of a peer's calls (implemented)

Replica `i` writes its calls to valkey database `db.offset + i` and keeps a
*foreign* copy of replica `(i + 1) mod replicaCount`'s, built from the keyspace
notifications on that database — the 1&1 active-active scheme (Kuzak, Kamailio
World 2016, slide 18). It was configured before and did nothing: valkey
publishes no keyspace events unless told to, and rtpengine never asks. The
chart now sets `notify-keyspace-events K$g` on its valkey (`$` the SET that
writes a call, `g` the DEL that ends it, the only two rtpengine acts on), adds
`redis =` without which a restart restores nothing, not even its own calls, and
`active-switchover`, which turns a foreign call into an own one on its first
packet or ng command. A lone replica gets neither the subscription nor the
switchover; it would subscribe to itself.

Measured against the daemon (27.0) with the rendered config, two replicas and
a valkey, driven over the ng socket:

| step | replica 0 own / foreign | replica 1 own / foreign |
| --- | --- | --- |
| offer + answer `c1` on 0 | 1 / 0 | 0 / 1 |
| restart 0 | 1 / 0 (restored) | 0 / 1 |
| kill 0, `answer` `c2` on 1 | — | 1 / 1 (`c2` promoted, written to db 9) |
| 0 comes back | 0 / 1 | 1 / 0 |
| `delete` with no delay on 0 | dropped | dropped |
| notifications off, offer on 0 | +1 own | no copy |

On its own this does not give media that survives the takeover. A restored
call keeps its ports but is bound by logical interface name and position, not
address, so replica 1 rebinds replica 0's call on *its own* address — 31244 on
172.19.0.4 where the far end is still sending to 172.19.0.3. That is what
per-owner addresses below are for. Two more things seen on the way: a failed-back replica leaves its
stale key for a promoted call in its own database, and the first answer on a
restored call logs `List of codecs empty`.

rtpengine cannot use a valkey cluster — it has no MOVED handling and keyspace
notifications are node-local — so the chart refuses `valkey.cluster.primaries > 1`.

### Per-owner addresses (implemented)

An interface with `vips` (and/or `vips6`) — one address per replica, outside
the attachment's IPAM range — answers offers from that address rather than
the pool's, and becomes one logical interface per owner, `<name>-<k>`. Each
replica configures two of them: its own first, which makes it its default,
and the one of the replica it is standby for. Every `direction=<name>` in
`templates` is rewritten per replica (`[templates-<i>]`), so the client still
names only `internal`/`outgoing`/`incoming`. A privileged init container
(`vip.sh` in the ConfigMap) sets `ip_nonlocal_bind` — the standby binds the
peer's address before it has it — and puts the replica's own address on the
device, with an unsolicited ARP for the MAC the previous pod left behind.

The ng control address follows: kamailio's rtpengine module keeps a call on
the node it was hashed to and never moves an existing call elsewhere, so
`RTPADR` becomes one node per replica on the control interface's VIP, and the
client has to be attached to that interface's network to reach it. Each
replica's `listen-ng` binds its own control VIP and its standby peer's, the
latter before it is on the pod (`ip_nonlocal_bind` again), so a VIP that has
moved is answered from where it now is. Without vips it binds the pod address
the Service leads to. It used to be `0.0.0.0`, which is how the table below
was measured; that also answered ng on every other interface, the TrGW's
on Ici included, and the HTTP port (`listen-http`, now the pod address too)
takes ng as well, at `POST /ng-plain`.

Nothing here moves an address yet. Measured with the rendered config in docker,
the address moved by hand (`ip addr add` + `arping -U` in the standby's netns)
in place of the failover that will do it:

| step | result |
| --- | --- |
| offer/answer on VIP0, RTP both ways | 20/20 each way from 172.30.0.251:36376 / :30284 |
| standby (replica 1) | foreign copy, and `netstat` shows it bound on 172.30.0.251:30284/36376 |
| replica 0 and its netns removed | 0/5 |
| VIP0 added to replica 1 | 20/20 each way, same address and ports; call promoted to own on the first packet |
| `query`/`delete` to 172.30.0.251:9910 | answered by replica 1 |

The validation refuses an interface whose vips are not one per replica, one
that is an alias or in a `base:suffix` round-robin group (the rest of the
group would be handed to its calls), one with an `advertised` address, and one
whose `address` is not a device.
