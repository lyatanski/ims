# Tracing

Two ways to see IMS signalling, both wired up in this repo, each answering a
different question.

| | question it answers | scope | run it with |
|---|---|---|---|
| [tcpdump](#tcpdump) | what was on the wire — SIP, Diameter, GTP, DNS, TCP, IPsec | all traffic | `--profile debug` |
| [webshark](#webshark) | which frames belong to one subscriber, whatever the protocol | any capture | `--profile debug` |

    docker compose --profile test --profile debug up -d

|  | |
|---|---|
| webshark | <http://localhost:8085> |

## tcpdump

One capture for the whole stack, in `monitor.yml` alongside the metrics it puts
packets behind. It binds to `ims0` — the compose bridge, whose name `compose.yml`
pins so the service can address it — and so holds every frame between containers
exactly once, and nothing that is not on the stack's own network.

    docker compose --profile debug up -d pcap
    wireshark pcap/trace.pcap

`-U` is set, so the file is valid up to its last frame at every moment. Copy it
out of a running capture; nothing has to be stopped first.

    docker compose cp pcap:/pcap/trace.pcap .

Expect infrastructure to dominate it: one run of the `test` profile held 20101
frames, of which ~1500 were signalling and the rest was redis, cadvisor, loki and
the scrapes.

### Which container did this frame come from?

Both ends of it, by MAC: a bridge capture is real Ethernet and the addresses are
the containers' own.

    docker compose ps -q | xargs docker inspect \
      -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.MacAddress}} {{.IPAddress}}{{end}}'

### Why the bridge works, and what binding to it costs

A socket on a bridge device sees forwarded frames only while that device is in
promiscuous mode — the kernel passes a copy up to the bridge itself only then.
`tcpdump` sets it and ptcpdump did not, which is the whole of the old claim that
a bound socket "sees almost nothing". Measured over one test run: **25 frames**
with `-p`, every one of them ARP or ICMPv6 and not a single SIP, Diameter or ESP
packet, against **3814** with promiscuous mode left on.

The cost is that one capture covers one bridge. `CORE=priv.yml` puts S5/S8 and
SGi on networks of their own, so it overrides the service back to `-i any`, which
sees every bridge — and the host too, hence the filter it carries there, and each
frame twice: leaving the sender as `sll.pkttype == 3`, arriving as `4`.

## webshark

Wireshark in the browser — `sharkd` behind a web UI, so the real dissectors over
the same `pcap/` directory.

    docker compose --profile debug up -d pcap webshark

<http://localhost:8085>
