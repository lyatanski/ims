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
packets behind. `-i any` binds to no interface, so it sees veths that do not
exist yet and depends on none of the stack being up.

    docker compose --profile debug up -d pcap
    wireshark pcap/trace.pcap

`-U` is set, so the file is valid up to its last frame at every moment. Copy it
out of a running capture; nothing has to be stopped first.

    docker compose cp pcap:/pcap/trace.pcap .

Two things are filtered out, because the capture attaches before the stack and
would otherwise be mostly neither: the registry traffic of `up` pulling images,
which was 270317 frames of a 342646-frame run against ~3700 of signalling, and
whatever shell is driving the host. Everything the stack itself does is kept.

### Which container did this frame come from?

There are no container names in the file — that was ptcpdump's job. Every frame
does carry the index of the veth it was seen on (`-i any` writes LINUX_SLL2), and
bridged traffic is seen twice: leaving the sender as `sll.pkttype == 3`, arriving
at the receiver as `4`. So one filter both deduplicates and attributes:

    sll.pkttype == 3

Leave it off and UDP counts double — 815 SIP frames for 410 messages in one run —
while Wireshark reads every delivered TCP segment as a retransmission of the sent
one and declines to dissect it: 12329 flagged, 3 with the filter on.

`tcpdump` prints `?` rather than the index's name, since it resolves against the
namespace reading the file rather than the one that captured it. Turn indices
into names from the running stack, before tearing it down:

    for c in $(docker compose ps -q); do
      printf '%s\t%s\n' \
        "$(docker run --rm --network container:$c alpine cat /sys/class/net/eth0/iflink)" \
        "$(docker inspect -f '{{.Name}}' $c)"
    done | sort -n

That reads the index from inside each namespace with a container of our own,
rather than `docker exec` — half the images here are distroless and have no `cat`
to exec. Two caveats. An index lives exactly as long as its veth, so recreate a
container and the table is stale; it is only meaningful against a capture from
the same run. And a service sharing another's namespace shares its index —
`trace` reads as `ocs` — while the ones in the host's namespace have no veth of
their own at all.

## webshark

Wireshark in the browser — `sharkd` behind a web UI, so the real dissectors over
the same `pcap/` directory.

    docker compose --profile debug up -d pcap webshark

<http://localhost:8085>
