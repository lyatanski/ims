# Tracing

Two ways to see IMS signalling, both wired up in this repo, each answering a
different question.

| | question it answers | scope | run it with |
|---|---|---|---|
| [ptcpdump](#ptcpdump) | what was on the wire — SIP, Diameter, GTP, DNS, TCP, IPsec | all traffic | `--profile debug` |
| [webshark](#webshark) | which frames belong to one subscriber, whatever the protocol | any capture | `--profile debug` |

    docker compose --profile test --profile debug up -d

|  | |
|---|---|
| webshark | <http://localhost:8085> |

## ptcpdump

[`ptcpdump`](https://github.com/mozillazg/ptcpdump) is tcpdump with the process
and container behind each packet attached, via eBPF. It is the answer to the
thing that makes plain captures painful here — a host capture shows
`veth50ec0b9 → 192.168.69.23` and leaves you to work out which container that
was:

```
13:04:39 veth50ec0b9 open5gs-hssd.259134 Out IP 192.168.69.8.3868 > 192.168.69.23.58240
         ParentProc [busybox.259032], Container [ims-hss-1]
```

The annotations are written into the pcapng as per-packet comments, so
Wireshark, `tshark` and webshark all show them with no plugin.

    docker compose --profile debug up -d pcap
    docker compose stop pcap        # flushes; do this before reading the file
    wireshark pcap/trace.pcapng

## webshark

Wireshark in the browser — `sharkd` behind a web UI, so the real dissectors and
ptcpdump's per-packet comments, over the same `pcap/` directory.

    docker compose --profile debug up -d pcap webshark
    docker compose stop pcap        # flushes; do this before opening the file

<http://localhost:8085>

