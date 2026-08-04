# Tracing

Three ways to see IMS signalling, all wired up in this repo, each answering a
different question.

| | question it answers | scope | run it with |
|---|---|---|---|
| [Homer](#homer) | what exactly was on the wire, message by message | SIP | `-f trace.yml` |
| [Tempo](#tempo) | where did the time go, across nodes and protocols | SIP + Diameter | `-f trace.yml` |
| [ptcpdump](#ptcpdump) | everything else — GTP, DNS, TCP, IPsec | all traffic | `--profile debug` |

`TRACING-ANALYSIS.md` in the repo root has the measurements and the reasoning
behind these choices, including what was rejected.

    docker compose -f compose.yml -f trace.yml --profile test up -d

|  | |
|---|---|
| Homer | <http://localhost:9080> — `admin` / `sipcapture` |
| Tempo | <http://localhost:3000> → Explore → Tempo, or the `traces` dashboard |
| webshark | <http://localhost:8085/webshark/> (`--profile debug`) |

## How it fits together

HEP is the common bus, so Homer and Tempo see identical input and can be judged
on it.

```
 pcscf ─┐
 icscf ─┼─ siptrace HEP3 ─▶ hepd ─┬─▶ homer   (HEP verbatim)
 scscf ─┘                         │
                                  └─▶ tempo   (OTLP spans) ─▶ grafana
 host netns:  dsniff ─ tcp/3868 ──┘
```

`hepd` forwards the HEP to Homer byte for byte, so the Homer path is exactly
what it would be if Tempo were not there. Only `hepd` derives spans.

### SIP: siptrace

[`siptrace`](https://kamailio.org/docs/modules/devel/modules/siptrace.html) with
`trace_init_mode=1` and `trace_mode=1` hooks Kamailio's core send/receive
callbacks and mirrors **every** SIP message as HEP3. No `sip_trace()` call and
no routing change: `proxy.cfg`, `interrogating.cfg` and `serving.cfg` are
untouched. The whole configuration is the `trace.cfg` config in `trace.yml`.

`common.cfg` picks it up with `import_file` rather than `include_file` —
`import_file` is silent when the file is missing, so the plain stack keeps
working and `trace.yml` is the only thing that delivers the file.

Each CSCF gets a distinct `hep_capture_id` (11/12/13 via `HEPID`), because that
numeric id is all siptrace carries to say which node a message came from;
`HEPMAP` on `hepd` turns it back into a name.

### Diameter: a sniffer

Nothing in the Diameter path can be asked to export anything: `cdp` has no trace
hook, and freeDiameter only offers `dbg_msg_dumps` into its log. So Diameter is
read off the wire by `dsniff`, which decodes the header plus the AVPs needed for
identity and correlation (Session-Id, Origin-Host, User-Name, Public-Identity,
Result-Code, Experimental-Result-Code).

Two things about that capture are worth knowing, both learned the hard way:

- **It has to run in the host network namespace.** On a bridge network a
  container only sees its own traffic; a sniffer sitting on the compose network
  never sees `scscf → hss`.
- **It must not bind to the bridge.** Traffic forwarded between two containers
  is tapped on the veth it entered through, never on the `br-<id>` device, so a
  socket bound to the bridge only sees packets addressed to the host itself —
  measured at 25 packets against 7094 unbound over the same window. `dsniff`
  therefore captures on every interface and removes the resulting duplicates
  by `(flow, sequence, length)`.

## Homer

Reference-grade SIP forensics: every message with its exact bytes and
timestamps, ladder diagrams, search by Call-ID or user, pcap export. If the
question is "what did the S-CSCF actually send", this is the tool.

This is **Homer 11** (`homer-core`), not the Homer 7 that most of the
`sipcapture/homer7-docker` material still describes. One Go binary with a
DuckLake store — a SQLite catalog over local Parquet — replacing Homer 7's
`heplify-server` + `homer-app` + PostgreSQL, with no schema to provision. It
classifies SIP on the way in, so a run lands as `hep_proto_1_registration`,
`hep_proto_1_call` and `hep_proto_1_default`.

Two operational notes:

- DuckDB fetches its `ducklake` extension from `extensions.duckdb.org` on every
  fresh start and a failed download is fatal, so the service carries
  `restart: on-failure`.
- The UI binds IPv4 only inside the container; the published port is
  `9080:8080` (container 9080 is Homer's *HTTP ingest*, which is unused here).

What it still does not do:

- **No Diameter.** Homer 11's field mappings cover SIP, RTCP, DNS, logs, SIPREC
  and OTLP — there is no Diameter table, and HEP has no registered Diameter
  payload type. Same gap as Homer 7.
- **No cross-protocol timeline.** HEP correlation is by Call-ID, so a Cx
  exchange cannot appear underneath the REGISTER that caused it.
- **No trace waterfalls in Grafana.** Homer 11 exposes Apache Arrow FlightSQL
  (consumed through Grafana's InfluxDB datasource), not the Tempo query API, so
  Grafana cannot draw a span waterfall or a service graph from it.

### Its OTLP receiver, and why the spans do not go there

Homer 11 ships a first-class OTLP receiver (`:4317` gRPC, `:4318` HTTP, into
`otlp_traces`), which is tempting: one backend for both the messages and the
spans. It is not used here because **its OTLP/JSON path base64-decodes `traceId`
and `spanId`**, where the OTLP spec explicitly requires hex for those two fields
in JSON. Sending `traceId=aabbccddeeff00112233445566778899` stores
`69a6db71c75d79e7dfd34d75db6df7e38e79ebaefbf3cf7d` — 24 bytes instead of 16,
exactly `hex(base64_decode(id))`. Every id is mangled and parent links break;
Tempo stores the identical payload correctly.

OTLP/protobuf carries the ids as raw bytes and so avoids the ambiguity, which is
the workaround if you want the spans in Homer as well — at the cost of encoding
protobuf in the agent.

## Tempo

The complement: it answers "where did the time go" rather than "what was sent".
`hepd` turns messages into **transaction** spans, so a span has a duration.

- A trace is a SIP dialog — trace id is `MD5(Call-ID)`, which needs no header
  propagation and lets every CSCF contribute independently.
- One span per node per transaction, nested in the order each node first saw the
  request, giving the P-CSCF → I-CSCF → S-CSCF waterfall.
- Diameter transactions (request → answer) hang underneath the SIP transaction
  that was open at the same node, so a registration reads as one tree:

```
REGISTER                  pcscf   18.9ms  401
  REGISTER                icscf   14.1ms  401
    Cx/UAR                icscf    3.8ms  erc=2002
    REGISTER              scscf    7.0ms  401
      Cx/MAR              scscf    5.0ms  rc=2001
REGISTER                  pcscf   14.7ms  200
  REGISTER                icscf    7.3ms  200
    REGISTER              scscf    5.9ms  200
      Cx/SAR              scscf    2.4ms  rc=2001
```

Tempo's metrics generator turns those spans into RED metrics and a service
graph, remote-written to Prometheus — the `traces` dashboard reads them, and the
Grafana node graph draws the reference points without anything declaring them.
Spans also link to Loki: the CSCFs prefix every log line with the Call-ID
(`xlog` `prefix` in `common.cfg`), which is what the `tracesToLogsV2` query on
the datasource uses.

### Where the correlation stops

3GPP defines no correlator between a SIP dialog and the Diameter session it
triggers, so attaching Cx/Rx/Ro to SIP is a heuristic: among the transactions
already open at that node, prefer an IMPU match, then the most recent one.
Consequences worth remembering before trusting a tree:

- Matching is on **capture timestamps, not arrival order** — the HEP feed and
  the Diameter feed are different sockets, so a Cx request can reach the
  collector before the REGISTER that caused it.
- With several transactions in flight at one node for the same user, a Diameter
  request can attach to the wrong one. An Rx AAR triggered by an INVITE will be
  filed under a PRACK if that PRACK started later.
- Messages with no SIP counterpart at all — base-application DWR/DWA, Gx, S6a —
  become their own traces rather than being forced under an unrelated dialog.
  `hepd` counts these as `orphan` in its stats line.

Spans are exported one second after a transaction completes, not immediately: a
proxy sees the final response twice, arriving and leaving, and flushing on first
sight would cut the span short and let the second copy open a duplicate.

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

**Start it before the traffic, not with it.** `-i any` attaches to the
interfaces that exist when ptcpdump enumerates, and loading its eBPF programs
takes about six seconds — brought up alongside the stack it captures on 3
interfaces out of 25 and quietly misses nine containers (220 packets and 4 SIP,
against 812 and 62 when started after the CSCFs are healthy). Nothing errors and
the packet count is non-zero, so this is only visible if you know what should be
there. Hence the `depends_on` and the healthcheck on the service, and the
two-step bring-up in CI. Interfaces appearing *after* it is running are picked
up normally.

It needs more than a capture privilege: `privileged` for loading eBPF, `pid:
host` (without which packets are still captured but nothing can be named), the
host network namespace, and `/sys/fs/cgroup` + `/run` for container lookup.
Kernel ≥ 5.2 with `CONFIG_DEBUG_INFO_BTF=y`.

The cost is size. The container metadata, including the full compose label set,
is repeated on every packet: **~1.4 kB per packet against ~150 bytes** for the
same traffic under plain tcpdump. Hence the filter on the service — RTP would
dwarf the signalling anyway.

## Viewing captures in a browser

- **webshark** (`--profile debug`) — `sharkd` behind a web UI, so the real
  Wireshark dissectors, including ptcpdump's comments. Two caveats: it lists
  `*.pcap` and ignores `.pcapng` entirely, so `cp pcap/trace.pcapng
  pcap/trace.pcap` first (same bytes; the format is detected from the magic);
  and it binds IPv4 only, which is why the port is published as
  `0.0.0.0:8085:8085`. Last real release August 2024.
- **wiregasm** — Wireshark compiled to WebAssembly, `@goodtools/wiregasm`. A
  library rather than an application, and fully client-side: nothing to deploy
  and captures never leave the browser. Actively maintained. Not wired up here
  because it would mean building a UI; it is the better foundation of the two if
  a viewer is ever wanted in-tree.

## Rejected

- **captagent** — HEP agent supporting Diameter as well as SIP, but wants a
  sidecar per monitored container, and Homer cannot store the Diameter anyway.
- **qryn** — does ingest HEP and speak the Tempo API, but stores in ClickHouse
  and renders SIP as log lines with a flow panel, not as spans with durations.
- **Kamailio → OTLP directly** — no such module exists. Building the spans in
  `http_client` calls from the config would also mean 64-bit nanosecond
  arithmetic, which the config language cannot do.
