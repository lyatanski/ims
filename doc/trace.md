# Tracing

Four ways to see IMS signalling, all wired up in this repo, each answering a
different question.

| | question it answers | scope | run it with |
|---|---|---|---|
| [Homer](#homer) | what exactly was on the wire, message by message | SIP | `-f trace.yml` |
| [Tempo](#tempo) | where did the time go, across nodes and protocols | SIP + Diameter | `-f trace.yml` |
| [ptcpdump](#ptcpdump) | everything else — GTP, DNS, TCP, IPsec | all traffic | `--profile debug` |
| [webshark](#webshark) | which frames belong to one subscriber, whatever the protocol | any capture | `--profile debug` |

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

## webshark

Wireshark in the browser — `sharkd` behind a web UI, so the real dissectors and
ptcpdump's per-packet comments, over the same `pcap/` directory.

    docker compose --profile debug up -d pcap webshark
    docker compose stop pcap        # flushes; do this before opening the file

<http://localhost:8085/webshark/>

Built here (`images/webshark`) rather than pulled from `ghcr.io/qxip/webshark`,
because the published image's own `sharkd -v` says **`without Lua`** — no plugin
can be loaded into it, and a plugin is what makes a capture answer IMS questions
instead of packet questions. `sharkd` tracks Wireshark master; the page and the
server around it are in `images/webshark/src`:

| | |
|---|---|
| UI | `src/web` — three files, vanilla JS, no framework and no build step |
| server | `src/*.go` — one static binary, stdlib only, JSON over a pipe to `sharkd` |
| image | plain `alpine` plus the libraries `sharkd` links, no Node anywhere |

It keeps the file list, upload, download, the display filter with validation, the
packet list, the dissection tree and the hex pane, and adds Wireshark's flow
graph as a second way to draw the list. What it drops is the rest of the tap menus
— Endpoints, Response Time, Statistics, Export Objects, Misc — which is most of
what the old Angular bundle was for.

Everything else about it follows from being ours:

- **The list draws two ways.** The header's `List`/`Flow` button — or `v` — swaps
  the packet list for a sequence diagram: a column per address, an arrow per frame
  from source lifeline to destination, its ports at the ends and the Info column
  over the line. The two views share the pages, the filter and the selection, so
  switching is a repaint and clicking an arrow opens that frame in the panes below.
- **Filter first.** The diagram's columns are the addresses of the pages fetched
  so far, up to 40 of them as in Wireshark — filtered to a subscriber or a call it
  is the conversation end to end (`ims.id` below crosses SIP and Diameter in one
  diagram); over a whole capture it is as wide as the capture is busy. A frame
  whose address did not fit still gets its row, as a line of text.
- **The arrow ports are hidden columns.** `sharkd` will not add a column on
  request, so `%uS`/`%uD` are in the column set from the start and marked not
  visible (`images/webshark/preferences`, the global Wireshark preferences file):
  the packet list skips them, the diagram labels its arrow ends with them.
- **Protected Gm reads as SIP.** Gm is behind IPsec ESP, and the keys of every
  registration are in the capture — so webshark takes them out of it and hands
  them to `sharkd` as ESP SAs when it opens the file ([below](#ipsec--the-keys-are-in-the-capture)).
- **`/plugins` is the plugin directory** (`WIRESHARK_PLUGIN_DIR`), mounted by
  `compose.yml` from `images/webshark/plugins`. Editing a plugin needs no
  rebuild: one `sharkd` per capture, so the next capture opened — or the same one
  after `Close` — runs the new code.
- **`tshark` and `dftest` sit next to `sharkd`**, so a plugin and a filter can be
  tried without a browser. The build fails if the example plugin does not load,
  if its fields do not compile into a filter, or if the server cannot serve its
  own page.
- **The packet list is paged**, 200 frames per request, drawn into recycled rows:
  the DOM holds a screenful whether the capture has 8 000 frames or 800 000.
  `sharkd` caches the filter's match bitmap, so paging a filtered capture costs
  one dissection per row drawn.
- **`sharkd` output goes to the browser unparsed**, except the packet list:
  `sharkd` repeats every pcapng comment in every row, and ptcpdump writes ~1.4 kB
  of container metadata per frame, so a page of 200 rows arrives as 246 kB and
  leaves as 34 kB — a 7× cut for data the list does not draw.
- **Dissectors are not kept forever.** At most `SHARKD_SESSIONS` (4) captures
  hold a `sharkd` at once, least recently used evicted first, and anything idle
  for `SHARKD_IDLE` (600 s) is closed — each one holds a whole dissected capture
  in memory. `Close` in the UI does it by hand.
- `.pcapng` files are listed, IPv6 works, and the URL carries the view
  (`#f=trace.pcapng&q=…&n=11&v=flow`), so a filtered packet — or the diagram it
  sits in — is a link.
- The header's theme button cycles **system → light → dark** and remembers the
  choice; left alone, the page follows the system setting.

Working on the UI without rebuilding the image:

    docker run --rm -p 8085:8085 -v ./pcap:/captures \
        -v ./images/webshark/src/web:/web -e WEB=/web \
        -v ./images/webshark/plugins:/plugins ghcr.io/lyatanski/webshark

### ims.lua — one filter across SIP and Diameter

`images/webshark/plugins/ims.lua` is the worked example of a plugin, and it
solves the problem [Tempo](#where-the-correlation-stops) also has to work
around: nothing on the wire relates a SIP dialog to the Diameter session it
triggers. The Cx `Session-Id` is minted by the CSCF and never appears in SIP;
the `Call-ID` never reaches the HSS. What both sides do carry is the subscriber,
spelled differently every time:

```
REGISTER   Authorization: username="001010000000001@ims.mnc01.mcc001..."
Cx UAR     User-Name = 001010000000001@ims.mnc01.mcc001...
Cx UAR     Public-Identity = sip:001010000000001@ims.mnc01.mcc001...
Gx CCR     Subscription-Id-Data = 001010000000001
INVITE     To: <tel:+359000000001>
```

The plugin normalizes all of those to the bare user part and adds it as a
generated field, so one filter reaches across both protocols:

| field | what it holds |
|---|---|
| `ims.id` | subscriber identity, once per distinct identity in the frame — so an INVITE matches under both parties |
| `ims.ref` | reference point: `Gm`, `Mw`, `Cx`, `Rx`, `Gx`, `Ro`, `Sh`, `S6a`, `base` |
| `ims.msg` | `Cx/UAR`, `Gx/CCA`, `REGISTER`, `REGISTER 401` — request bit and CSeq method resolved |
| `ims.linked` | set when the identity came from session state rather than from this frame |

```
$ tshark -r pcap/trace.pcapng -Y 'ims.id == "001010000000001"' \
      -T fields -e frame.number -e ims.ref -e ims.msg -e ims.linked
     5  Mw   REGISTER
     6  Mw   REGISTER
     7  Cx   Cx/UAR
    11  Cx   Cx/UAA        True
    23  Cx   Cx/MAR
    27  Cx   Cx/MAA
    31  Mw   REGISTER 401
    41  Gm   REGISTER 401
    57  Cx   Cx/SAR
    63  Cx   Cx/SAA
    69  Mw   REGISTER 200
```

The whole registration in one filter: the UAR the I-CSCF asked, the MAR that
produced the challenge, the 401 on its way back to the UE, then the SAR after
the UE authenticated — and frame 11, a UAA that carries a `Session-Id` and no
identity at all, pulled in because its request had one.

Same filter in the webshark search box, or through `sharkd` directly. On the
8263-frame capture in `pcap/` one subscriber comes out as 50 frames across four
reference points — 30 Mw, 13 Cx, 5 Gm, 2 Gx — which is the whole point: the Cx
exchange the HSS saw and the SIP that caused it, selected by who it was about
rather than by which node or port.

Two mechanisms are worth knowing before trusting it:

- **`Gm` versus `Mw` is a preference, not a fact on the wire.** They are the
  same protocol on the same port, so the plugin calls a SIP frame `Gm` when one
  endpoint is inside `ims.ue_subnet` (default `10.10.0.0/16`, the stack's
  `UENET`) and `Mw` otherwise. Override with `-o ims.ue_subnet:10.0.0.0/8`.
- **Diameter answers are stitched, and only from what was captured.** A UAA or
  CCA carries a `Session-Id` and no identity, so the identity is remembered per
  session from the request — `ims.linked` marks those. If the request was never
  captured the answer has no identity at all: 27 of the 368 Cx frames in
  `pcap/trace.pcapng` are UAAs whose UAR is simply not in the file. SIP needs
  none of this, since From and To are in every message including responses.

Adding a plugin of your own is a file in the same directory — `Proto`,
`ProtoField`s, `register_postdissector()` — and the next capture you open picks
it up.

### IPsec — the keys are in the capture

Gm is protected. 3GPP puts IPsec ESP in transport mode between the UE and the
P-CSCF (TS 33.203), so everything the UE sends after it authenticates — every
re-REGISTER, INVITE, MESSAGE, SUBSCRIBE — is ESP payload, and Wireshark's default
is to show `ESP (SPI=0x00000101)` and stop. Two things in the image change that.

**The preferences.** `images/webshark/preferences` turns on all three of
Wireshark's ESP switches, off by default: the NULL-encryption heuristic, the
keyed decode over the SA table, and the integrity check. The heuristic needs no
keys at all — it finds the payload by recognising the ESP trailer behind it — and
that alone covers this stack, which negotiates `ealg=null`.

**The keys**, for the traffic where it does not. IPsec on Gm is keyed from AKA
rather than from IKE: the four SAs of a registration take CK as their encryption
key and IK as their integrity key, and those travel through the capture in the
clear — across three messages, none of which holds all of it:

```
REGISTER Gm  Security-Client: ...;spi-c=8193;spi-s=8194        what the UE receives on
401      Mw  WWW-Authenticate: ...,ck="46ccd0…",ik="06c149…"   the keys
401      Gm  Security-Server: ...;spi-c=256;spi-s=257          what the P-CSCF receives on
```

The P-CSCF takes `ck` and `ik` out of the 401 before the UE sees it — that is what
they are travelling in it for — so the keys are on the Mw leg and the SPIs on the
Gm leg. What relates the two is the `Call-ID`, the one field all three carry.
`src/esp.go` reads those fields in one `tshark -T fields` pass and writes
Wireshark's own SA syntax, four records per registration:

```
"IPv4","10.10.0.2","192.168.69.70","0x00000101","NULL","","HMAC-SHA-1-96 [RFC2404]","0x06c149b9b76fffa0ec5643ba58c28a0600000000"
```

Four, because the SPIs a party hands out are the ones it will receive on: the
P-CSCF's two go on the frames sent to it, the UE's two on the frames sent back,
and Wireshark matches an SA by source, destination and SPI. The keys are expanded
as TS 33.203 Annex I says — IK padded to 160 bits for `hmac-sha-1-96`, CK to 192
for `des-ede3-cbc`, both as they are for `hmac-md5-96` and `aes-cbc`.

Nothing has to be run for this: every `sharkd` started here is given the SAs of
the capture it opened, through sharkd's `setconf`, in the pass that runs while the
file is loading — `esp: trace.pcapng: 160 SAs from the capture` in the container
log. The same list is printable for the programs next to it:

    docker exec ims-webshark-1 webshark -esp /captures/trace.pcapng
    docker exec ims-webshark-1 sh -c \
        'webshark -esp /captures/trace.pcapng > /root/.config/wireshark/esp_sa'

the second being the file `tshark`, `dftest` and Wireshark itself all read.

On a 52 000-frame capture of 40 registered UEs that is 160 SAs, and all 923 ESP
frames in it come out as the SIP they hold: `esp && ims.id == "001010000000001"`
reaches inside them, the flow diagram labels its arrows with the ports from within
the SA, and every frame's tree ends its ESP node with `ESP ICV … [correct]` —
which is the part that matters. A key that came out of the capture wrong dissects
just as readably and says `[incorrect]` instead.

Three things to know before trusting it:

- **The keys have to be on the Mw leg of the capture.** No `ck`/`ik` in a 401 —
  an S-CSCF that does not send them, a leg that was not captured — is no SAs.
  `ealg=null` traffic still reads through the heuristic; encrypted traffic does
  not read at all.
- **The Cx MAA carries the same CK and IK** (`diameter.Confidentiality-Key`,
  `diameter.Integrity-Key`) and is deliberately not used. Nothing in it says which
  SA the keys belong to, so pairing them with a registration would be a guess,
  where the 401 is a fact.
- **A registration challenged again** gets new keys and new SPIs, and both sets
  are kept: the SPIs differ, so the old records match the old frames and the new
  ones the new. A pairing that went wrong is visible as `[incorrect]` rather than
  as a wrong dissection.

### wiregasm

Wireshark compiled to WebAssembly, `@goodtools/wiregasm`. A library rather than
an application, and fully client-side: nothing to deploy and captures never
leave the browser. Actively maintained. Not wired up here because it would mean
building a UI; it is the better foundation of the two if a viewer is ever wanted
in-tree.

## Rejected

- **captagent** — HEP agent supporting Diameter as well as SIP, but wants a
  sidecar per monitored container, and Homer cannot store the Diameter anyway.
- **qryn** — does ingest HEP and speak the Tempo API, but stores in ClickHouse
  and renders SIP as log lines with a flow panel, not as spans with durations.
- **Kamailio → OTLP directly** — no such module exists. Building the spans in
  `http_client` calls from the config would also mean 64-bit nanosecond
  arithmetic, which the config language cannot do.
