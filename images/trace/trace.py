#!/usr/bin/env python3
"""IMS signalling -> OpenTelemetry spans.

Neither Kamailio nor freeDiameter speaks OTLP, and no off-the-shelf agent
turns SIP *and* Diameter into spans, so this is the missing piece between the
existing HEP world (Homer) and Tempo. HEP is used as the common bus: SIP
arrives from Kamailio's own siptrace module, Diameter from the sniffer role
below, and both end up in the same trace.

Two roles, picked by argv[1]:

  collector  Receive HEP3 on UDP/9060 (SIP, from siptrace) and Diameter events
             on UDP/9061 (from the sniffer). Stitch messages into per-node
             transaction spans, parent them into one trace per SIP dialog, and
             export to an OTLP/HTTP endpoint. The raw HEP is optionally teed
             verbatim to heplify-server, so Homer sees exactly the same bytes
             and the two backends can be compared on equal input.

  sniffer    Read Diameter off the Docker bridge with AF_PACKET, reassemble the
             TCP stream, decode the header plus the handful of AVPs needed for
             correlation, and forward each message to the collector as JSON.
             Diameter is captured rather than instrumented because cdp (the
             Kamailio Diameter stack) has no trace hook at all.

Correlation, and where it stops:

  SIP        trace id = MD5(Call-ID), so every CSCF that touches a dialog
             contributes to one trace without any header propagation. Spans
             nest in the order each node first saw the request, which yields
             the P-CSCF > I-CSCF > S-CSCF waterfall.

  Diameter   A Cx/Rx/Ro request is attached to whichever SIP transaction was
             open at the same node when it was sent, preferring an IMPU match
             (Public-Identity / User-Name vs the SIP To user). This is a
             heuristic: 3GPP defines no correlator between a SIP dialog and the
             Diameter session it triggers. When nothing matches, the message
             becomes its own trace keyed by Session-Id rather than being
             attached to the wrong dialog.

Standard library only - the point is that this stays a readable single file.
"""

import hashlib
import json
import os
import queue
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

OTLP = os.environ.get("OTLP", "http://tempo:4318/v1/traces")
HEP_LISTEN = int(os.environ.get("HEP_LISTEN", "9060"))
DIA_LISTEN = int(os.environ.get("DIA_LISTEN", "9061"))
HEP_FORWARD = os.environ.get("HEP_FORWARD", "")        # host:port of heplify-server
COLLECTOR = os.environ.get("COLLECTOR", "127.0.0.1:9061")
DIA_PORT = int(os.environ.get("DIA_PORT", "3868"))
# siptrace only carries a numeric capture id, so the node names come from here
HEPMAP = os.environ.get("HEPMAP", "11=pcscf,12=icscf,13=scscf")
# a transaction with no final response is flushed once it has been idle this long
IDLE = float(os.environ.get("IDLE", "5"))
# grace period after the last final response. A proxy sees that response twice
# (arriving, then leaving), so flushing on first sight would cut the span short
# and let the second copy open a duplicate transaction.
LINGER = float(os.environ.get("LINGER", "1"))
BATCH = float(os.environ.get("BATCH", "1"))
# tolerance when deciding whether a Diameter request falls inside a SIP
# transaction: the two feeds are timestamped by different clocks
SKEW = float(os.environ.get("SKEW", "0.05"))


def log(*a):
    print(*a, file=sys.stderr, flush=True)


NODES = {}
for _pair in HEPMAP.split(","):
    if "=" in _pair:
        _k, _v = _pair.split("=", 1)
        NODES[_k.strip()] = _v.strip()


# ---------------------------------------------------------------------------
# HEP3
# ---------------------------------------------------------------------------

def hep_parse(buf):
    """Decode a HEP3 datagram into a dict of chunk type -> raw bytes."""
    if len(buf) < 6 or buf[:4] != b"HEP3":
        return None
    total = struct.unpack("!H", buf[4:6])[0]
    if total > len(buf):
        return None
    out, off = {}, 6
    while off + 6 <= total:
        vendor, ctype, clen = struct.unpack("!HHH", buf[off:off + 6])
        if clen < 6 or off + clen > total:
            break
        # only the generic vendor (0) carries the chunks used here
        if vendor == 0:
            out[ctype] = buf[off + 6:off + clen]
        off += clen
    return out


def hep_fields(chunks):
    """Pull the interesting HEP chunks out into normal Python values."""
    def num(t):
        v = chunks.get(t)
        if not v:
            return None
        return int.from_bytes(v, "big")

    src = dst = None
    if 3 in chunks:
        src = socket.inet_ntop(socket.AF_INET, chunks[3])
    elif 5 in chunks:
        src = socket.inet_ntop(socket.AF_INET6, chunks[5])
    if 4 in chunks:
        dst = socket.inet_ntop(socket.AF_INET, chunks[4])
    elif 6 in chunks:
        dst = socket.inet_ntop(socket.AF_INET6, chunks[6])

    ts = (num(9) or int(time.time())) + (num(10) or 0) / 1e6
    return {
        "src": src, "dst": dst,
        "sport": num(7), "dport": num(8),
        "ts": ts,
        "proto": num(11) or 0,
        "capid": num(12) or 0,
        "payload": chunks.get(15, b""),
    }


# ---------------------------------------------------------------------------
# SIP
# ---------------------------------------------------------------------------

def sip_parse(payload):
    """Extract just enough of a SIP message to build a span out of it."""
    try:
        text = payload.decode("utf-8", "replace")
    except Exception:
        return None
    head = text.split("\r\n\r\n", 1)[0]
    lines = head.replace("\r\n", "\n").split("\n")
    if not lines or not lines[0].strip():
        return None
    start = lines[0].strip()

    m = {"start": start, "callid": None, "cseq": None, "method": None,
         "code": None, "reason": "", "to": None, "from": None, "request": False}

    if start.upper().startswith("SIP/2.0"):
        parts = start.split(None, 2)
        if len(parts) < 2 or not parts[1].isdigit():
            return None
        m["code"] = int(parts[1])
        m["reason"] = parts[2] if len(parts) > 2 else ""
    else:
        parts = start.split()
        if len(parts) < 3 or not parts[-1].upper().startswith("SIP/"):
            return None
        m["request"] = True
        m["method"] = parts[0].upper()
        m["ruri"] = parts[1]

    for line in lines[1:]:
        if ":" not in line:
            continue
        name, _, value = line.partition(":")
        name = name.strip().lower()
        value = value.strip()
        if name in ("call-id", "i"):
            m["callid"] = value
        elif name == "cseq":
            bits = value.split()
            if bits and bits[0].isdigit():
                m["cseq"] = int(bits[0])
            if len(bits) > 1:
                m["method"] = bits[1].upper()
        elif name in ("to", "t"):
            m["to"] = value
        elif name in ("from", "f"):
            m["from"] = value

    if not m["callid"] or m["cseq"] is None or not m["method"]:
        return None
    return m


def uri_user(header):
    """sip:alice@example.com;tag=x  ->  alice"""
    if not header:
        return None
    s = header
    if "<" in s:
        s = s[s.index("<") + 1:]
        if ">" in s:
            s = s[:s.index(">")]
    for scheme in ("sip:", "sips:", "tel:"):
        if s.lower().startswith(scheme):
            s = s[len(scheme):]
            break
    s = s.split(";")[0]
    if "@" in s:
        s = s.split("@")[0]
    return s.strip() or None


# ---------------------------------------------------------------------------
# Diameter
# ---------------------------------------------------------------------------

CMD = {
    257: "CER", 258: "RAR", 265: "AAR", 271: "ACR", 272: "CCR", 274: "ASR",
    275: "STR", 280: "DWR", 282: "DPR", 300: "UAR", 301: "SAR", 302: "LIR",
    303: "MAR", 304: "RTR", 305: "PPR", 316: "ULR", 318: "AIR",
}
# answers reuse the command code, only the R bit differs
ANS = {
    257: "CEA", 258: "RAA", 265: "AAA", 271: "ACA", 272: "CCA", 274: "ASA",
    275: "STA", 280: "DWA", 282: "DPA", 300: "UAA", 301: "SAA", 302: "LIA",
    303: "MAA", 304: "RTA", 305: "PPA", 316: "ULA", 318: "AIA",
}
APP = {
    0: "base", 3: "Rf", 4: "Ro", 16777216: "Cx", 16777236: "Rx",
    16777238: "Gx", 16777251: "S6a", 16777252: "S13", 16777291: "Sh",
}
# AVPs worth decoding: identity, correlation and result
AVP_STR = {1: "user", 263: "sid", 264: "origin", 293: "dest", 296: "origin_realm",
           283: "dest_realm", 601: "impu", 700: "impi"}
AVP_U32 = {268: "rc", 298: "erc", 416: "cc_type", 415: "cc_num"}


def diameter_avps(buf, depth=0):
    """Walk top-level AVPs; recurse once into grouped ones (3GPP nests results)."""
    out, off, end = {}, 0, len(buf)
    while off + 8 <= end:
        code, flags_len = struct.unpack("!II", buf[off:off + 8])
        flags = flags_len >> 24
        length = flags_len & 0xFFFFFF
        if length < 8 or off + length > end:
            break
        pos = off + 8
        if flags & 0x80:                      # vendor specific
            if off + 12 > end:
                break
            pos += 4
        data = buf[pos:off + length]
        if code in AVP_STR:
            out[AVP_STR[code]] = data.decode("utf-8", "replace").strip("\x00")
        elif code in AVP_U32 and AVP_U32[code] and len(data) >= 4:
            out[AVP_U32[code]] = struct.unpack("!I", data[:4])[0]
        elif code in (297, 458, 456) and depth == 0:
            # Experimental-Result / Multiple-Services-Credit-Control etc.
            out.update(diameter_avps(data, depth + 1))
        off += (length + 3) & ~3              # AVPs are padded to 4 bytes
    return out


def diameter_parse(msg):
    """Decode one complete Diameter message."""
    if len(msg) < 20 or msg[0] != 1:
        return None
    length = int.from_bytes(msg[1:4], "big")
    flags = msg[4]
    code = int.from_bytes(msg[5:8], "big")
    app, hbh, e2e = struct.unpack("!III", msg[8:20])
    req = bool(flags & 0x80)
    out = {
        "req": req, "cmd": code, "app": app, "hbh": hbh, "e2e": e2e,
        "name": (CMD if req else ANS).get(code, ("R" if req else "A") + str(code)),
        "app_name": APP.get(app, str(app)),
        "len": length,
    }
    out.update(diameter_avps(msg[20:length]))
    return out


# ---------------------------------------------------------------------------
# OTLP export
# ---------------------------------------------------------------------------

def hexid(seed, size):
    return hashlib.md5(seed.encode("utf-8", "replace")).hexdigest()[:size]


def attrs(d):
    out = []
    for k, v in d.items():
        if v is None:
            continue
        if isinstance(v, bool):
            val = {"boolValue": v}
        elif isinstance(v, int):
            val = {"intValue": str(v)}
        elif isinstance(v, float):
            val = {"doubleValue": v}
        else:
            val = {"stringValue": str(v)}
        out.append({"key": k, "value": val})
    return out


def nano(ts):
    return str(int(ts * 1e9))


class Exporter(threading.Thread):
    """Batches finished spans and POSTs them as OTLP/HTTP JSON."""

    def __init__(self, endpoint):
        # daemon has to go through the constructor: setting it as a class
        # attribute only shadows Thread's property and leaves the real flag off
        super().__init__(name="exporter", daemon=True)
        self.endpoint = endpoint
        self.q = queue.Queue()
        self.sent = 0
        self.failed = 0

    def submit(self, span):
        self.q.put(span)

    def run(self):
        while True:
            batch = []
            deadline = time.time() + BATCH
            while time.time() < deadline and len(batch) < 500:
                try:
                    batch.append(self.q.get(timeout=max(0.05, deadline - time.time())))
                except queue.Empty:
                    break
            if batch:
                self._post(batch)

    def _post(self, batch):
        # OTLP groups spans by resource, so bucket them per service first
        by_service = {}
        for s in batch:
            by_service.setdefault(s.pop("_service"), []).append(s)
        body = {"resourceSpans": [
            {
                "resource": {"attributes": attrs({
                    "service.name": svc,
                    "service.namespace": "ims",
                })},
                "scopeSpans": [{
                    "scope": {"name": "ims-trace-agent"},
                    "spans": spans,
                }],
            }
            for svc, spans in by_service.items()
        ]}
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            self.endpoint, data=data,
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                r.read()
            self.sent += len(batch)
        except urllib.error.HTTPError as e:
            self.failed += len(batch)
            log("otlp %s: %s %s" % (self.endpoint, e.code, e.read()[:200]))
        except Exception as e:
            self.failed += len(batch)
            log("otlp %s: %s" % (self.endpoint, e))


# ---------------------------------------------------------------------------
# correlation
# ---------------------------------------------------------------------------

class Tracer:
    """Holds open transactions and turns them into spans as they complete.

    Two tables, both keyed so that every node that touches a dialog lands in
    the same trace:

      sip[(callid, cseq, method)]  ->  one entry per node, in first-seen order
      dia[(hbh, e2e)]              ->  one entry per Diameter transaction
    """

    def __init__(self, exporter):
        self.exp = exporter
        self.sip = {}
        self.dia = {}
        self.flushed = {}
        # spans already exported, kept briefly so a late Diameter answer can
        # still find the SIP transaction it belongs under
        self.recent = []
        self.lock = threading.Lock()
        self.stats = {"sip": 0, "dia": 0, "spans": 0, "orphan": 0, "late": 0}

    # -- SIP ---------------------------------------------------------------

    def on_sip(self, msg, meta):
        node = NODES.get(str(meta["capid"]), "cap%s" % meta["capid"])
        key = (msg["callid"], msg["cseq"], msg["method"])
        ts = meta["ts"]
        with self.lock:
            self.stats["sip"] += 1
            txn = self.sip.get(key)
            if txn is None:
                if key in self.flushed:
                    # a retransmission of a transaction already exported
                    self.stats["late"] += 1
                    return
                txn = self.sip[key] = {
                    "trace": hexid(msg["callid"], 32),
                    "nodes": {},
                    "touched": time.time(),
                }
            txn["touched"] = max(txn["touched"], time.time())

            span = txn["nodes"].get(node)
            if span is None:
                # nest under the node that saw this request before us
                prior = list(txn["nodes"].values())
                span = txn["nodes"][node] = {
                    "id": hexid("%s|%s|%s|%s" % (msg["callid"], msg["cseq"],
                                                 msg["method"], node), 16),
                    "parent": prior[-1]["id"] if prior else None,
                    "start": ts,
                    "end": ts,
                    "events": [],
                    "code": None,
                    "impu": uri_user(msg.get("to")),
                    "done": False,
                    "children": [],
                }
            span["start"] = min(span["start"], ts)
            span["end"] = max(span["end"], ts)

            if msg["code"] is not None:
                span["events"].append((ts, "%s %s" % (msg["code"], msg["reason"])))
                if msg["code"] >= 200:
                    span["code"] = msg["code"]
                    span["done"] = True
            else:
                span["events"].append((ts, msg["start"].split(None, 2)[0]))

            # The root node is created first and finishes last (it holds the
            # transaction open until the final response is on its way back to
            # the UE), so "every node done" means the transaction is over. The
            # actual export waits out LINGER in sweep().
            txn["complete"] = all(s["done"] for s in txn["nodes"].values())

    def _flush_sip(self, key, txn):
        self.flushed[key] = time.time()
        callid, cseq, method = key
        now = time.time()
        for node, span in txn["nodes"].items():
            code = span["code"]
            self.recent.append(
                (node, txn["trace"], span["id"], span["start"], span["impu"], now))
            self._emit(
                service=node,
                trace=txn["trace"],
                span_id=span["id"],
                parent=span["parent"],
                name=method,
                kind=2,
                start=span["start"],
                end=span["end"],
                events=span["events"],
                error=code is not None and code >= 400,
                status_msg="%s" % code if code else "no final response",
                attributes={
                    "ims.protocol": "sip",
                    "sip.method": method,
                    "sip.call_id": callid,
                    "sip.cseq": cseq,
                    "sip.response_code": code,
                    "ims.impu": span["impu"],
                    "ims.node": node,
                },
            )
        for child in txn.get("children", []):
            self._emit(**child)
        self.sip.pop(key, None)

    # -- Diameter ----------------------------------------------------------

    def on_diameter(self, ev):
        key = (ev["hbh"], ev["e2e"])
        ts = ev["ts"]
        node = ev.get("node") or "diameter"
        with self.lock:
            self.stats["dia"] += 1
            if ev["req"]:
                self.dia[key] = {"start": ts, "ev": ev, "node": node}
                return
            txn = self.dia.pop(key, None)
            if txn is None:
                # answer without a request in view - still worth a zero span
                txn = {"start": ts, "ev": ev, "node": node}
            self._flush_dia(txn, ev, ts)

    def _candidates(self, node):
        for key, txn in self.sip.items():
            span = txn["nodes"].get(node)
            if span:
                yield (txn["trace"], span["id"], span["start"], span["impu"], key)
        for rec in self.recent:
            if rec[0] == node:
                # key None: already exported, so there is nothing to defer to
                yield rec[1:5] + (None,)

    def _link(self, node, dia_ts, ev):
        """Attach a Diameter transaction to the SIP transaction that triggered it.

        Matched on capture timestamps rather than arrival order: HEP and the
        Diameter feed are separate sockets, so a Cx request can reach the
        collector before the REGISTER that caused it. Among the transactions
        that had already started at this node, the most recent one wins - that
        is the innermost enclosing transaction - and an IMPU match beats one
        that merely overlaps in time.
        """
        impu = ev.get("impu") or ev.get("user") or ""
        impu_user = uri_user(impu) or (impu.split("@")[0] if "@" in impu else impu)
        best = None
        for trace, span_id, start, span_impu, key in self._candidates(node):
            if dia_ts + SKEW < start:
                continue                       # the SIP request was not in yet
            match = bool(impu_user) and span_impu == impu_user
            if impu_user and not match:
                continue                       # named a user, but not this one
            rank = (1 if match else 0, start)
            if best is None or rank > best[0]:
                best = (rank, {"trace": trace, "parent": span_id, "key": key})
        if best is None:
            self.stats["orphan"] += 1
            return None
        return best[1]

    def _flush_dia(self, txn, ans, end, answered=True):
        ev = txn["ev"]
        rc = ans.get("rc")
        erc = ans.get("erc")
        failed = (rc is not None and rc >= 3000) or (erc is not None and erc >= 4000)
        span = dict(
            service=txn["node"],
            trace=None, span_id=None, parent=None,
            name="%s/%s" % (ev["app_name"], ev["name"]), kind=3,
            start=txn["start"], end=max(end, txn["start"]),
            events=[],
            error=bool(failed) or not answered,
            status_msg=("rc=%s erc=%s" % (rc, erc)) if answered else "no answer",
            attributes={
                "ims.protocol": "diameter",
                "diameter.application": ev["app_name"],
                "diameter.application_id": ev["app"],
                "diameter.command": ev["name"],
                "diameter.command_code": ev["cmd"],
                "diameter.session_id": ev.get("sid"),
                "diameter.origin_host": ev.get("origin"),
                "diameter.destination_host": ev.get("dest"),
                "diameter.result_code": rc,
                "diameter.experimental_result_code": erc,
                "ims.impu": ev.get("impu"),
                "ims.impi": ev.get("user") or ev.get("impi"),
                "ims.node": txn["node"],
            },
        )
        span["span_id"] = hexid("%s|%s|%s" % (ev["hbh"], ev["e2e"], ev["name"]), 16)
        link = self._link(txn["node"], txn["start"], ev)
        if link:
            span["trace"] = link["trace"]
            span["parent"] = link["parent"]
            parent_txn = self.sip.get(link["key"])
            if parent_txn is not None:
                # hold it back so it never reaches Tempo before its parent
                parent_txn.setdefault("children", []).append(span)
                return
            # parent already flushed - Tempo accepts children out of order
            self._emit(**span)
            return
        span["trace"] = hexid(ev.get("sid") or "%s|%s" % (ev["hbh"], ev["e2e"]), 32)
        self._emit(**span)

    # -- emit / sweep ------------------------------------------------------

    def _emit(self, service, trace, span_id, parent, name, kind, start, end,
              events, error, status_msg, attributes):
        span = {
            "_service": service,
            "traceId": trace,
            "spanId": span_id,
            "name": name,
            "kind": kind,
            "startTimeUnixNano": nano(start),
            "endTimeUnixNano": nano(end),
            "attributes": attrs(attributes),
            "status": {"code": 2, "message": status_msg} if error
                      else {"code": 1},
        }
        if parent:
            span["parentSpanId"] = parent
        if events:
            span["events"] = [
                {"timeUnixNano": nano(t), "name": n} for t, n in sorted(events)
            ]
        self.stats["spans"] += 1
        self.exp.submit(span)

    def sweep(self):
        """Export what is finished and give up on what went quiet.

        A completed transaction waits out LINGER so both copies of the final
        response land in the same span; an incomplete one (lost final response,
        or a one-way message like a NOTIFY that was never answered) is cut
        loose after IDLE rather than pinning the trace open forever.
        """
        now = time.time()
        with self.lock:
            for key in [k for k, t in self.dia.items() if now - t["start"] > IDLE]:
                txn = self.dia.pop(key)
                self._flush_dia(txn, {}, txn["start"], answered=False)
            ripe = [
                k for k, t in self.sip.items()
                if now - t["touched"] > (LINGER if t.get("complete") else IDLE)
            ]
            for key in ripe:
                self._flush_sip(key, self.sip[key])
            for key in [k for k, t in self.flushed.items() if now - t > 30]:
                self.flushed.pop(key, None)
            self.recent = [r for r in self.recent if now - r[5] < 30]


# ---------------------------------------------------------------------------
# collector role
# ---------------------------------------------------------------------------

def role_collector():
    exp = Exporter(OTLP)
    exp.start()
    tracer = Tracer(exp)

    fwd_addr = None
    if HEP_FORWARD:
        host, _, port = HEP_FORWARD.partition(":")
        fwd_addr = (host, int(port or 9060))
    fwd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def hep_loop():
        s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        s.bind(("::", HEP_LISTEN))
        log("collector: HEP on :%d -> %s" % (HEP_LISTEN, OTLP))
        while True:
            try:
                buf, _ = s.recvfrom(65535)
            except OSError:
                continue
            if fwd_addr:
                # verbatim tee: Homer must see exactly what siptrace sent
                try:
                    fwd.sendto(buf, fwd_addr)
                except OSError as e:
                    log("tee: %s" % e)
            chunks = hep_parse(buf)
            if not chunks:
                continue
            meta = hep_fields(chunks)
            if meta["proto"] not in (0, 1):        # 1 = SIP
                continue
            msg = sip_parse(meta["payload"])
            if msg:
                try:
                    tracer.on_sip(msg, meta)
                except Exception as e:
                    log("sip: %r" % e)

    def dia_loop():
        s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.bind(("::", DIA_LISTEN))
        log("collector: diameter events on :%d" % DIA_LISTEN)
        while True:
            try:
                buf, _ = s.recvfrom(65535)
            except OSError:
                continue
            try:
                ev = json.loads(buf)
            except Exception:
                continue
            try:
                tracer.on_diameter(ev)
            except Exception as e:
                log("diameter: %r" % e)

    for fn in (hep_loop, dia_loop):
        threading.Thread(target=fn, daemon=True, name=fn.__name__).start()

    last = 0
    while True:
        time.sleep(1)
        try:
            tracer.sweep()
        except Exception as e:
            log("sweep: %r" % e)
        if time.time() - last > 30:
            last = time.time()
            log("stats sip=%d diameter=%d spans=%d sent=%d failed=%d orphan=%d"
                % (tracer.stats["sip"], tracer.stats["dia"], tracer.stats["spans"],
                   exp.sent, exp.failed, tracer.stats["orphan"]))


# ---------------------------------------------------------------------------
# sniffer role
# ---------------------------------------------------------------------------

def role_sniffer():
    host, _, port = COLLECTOR.partition(":")
    dest = (host, int(port or DIA_LISTEN))
    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Deliberately unbound, i.e. every interface, the equivalent of `-i any`.
    #
    # Binding to the compose bridge looks tidier but captures almost nothing:
    # traffic forwarded between two containers is tapped on the veth it entered
    # through, never on the bridge device, so a socket bound to br-<id> only
    # sees the packets addressed to the host itself. Measured on this stack:
    # 7094 packets unbound against 25 bound, over the same window.
    #
    # The cost is seeing each packet more than once - sender veth, receiver
    # veth - which the dedup below takes back out.
    s = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(0x0003))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    log("sniffer: diameter tcp/%d on all interfaces -> %s:%d"
        % (DIA_PORT, dest[0], dest[1]))

    streams = {}
    seen = {}
    stats = {"msg": 0, "dup": 0}
    last = time.time()

    while True:
        try:
            data, addr = s.recvfrom(65535)
        except OSError:
            continue
        proto = addr[1]
        now = time.time()

        if proto == 0x0800:
            if len(data) < 20 or (data[0] >> 4) != 4:
                continue
            ihl = (data[0] & 0x0F) * 4
            if data[9] != 6 or len(data) < ihl + 20:
                continue
            src = socket.inet_ntop(socket.AF_INET, data[12:16])
            dst = socket.inet_ntop(socket.AF_INET, data[16:20])
            seg = data[ihl:]
        elif proto == 0x86DD:
            if len(data) < 40 or data[6] != 6:
                continue
            src = socket.inet_ntop(socket.AF_INET6, data[8:24])
            dst = socket.inet_ntop(socket.AF_INET6, data[24:40])
            seg = data[40:]
        else:
            continue

        if len(seg) < 20:
            continue
        sport, dport = struct.unpack("!HH", seg[0:4])
        if DIA_PORT not in (sport, dport):
            continue
        seq = struct.unpack("!I", seg[4:8])[0]
        doff = (seg[12] >> 4) * 4
        if doff < 20 or len(seg) < doff:
            continue
        payload = seg[doff:]
        if not payload:
            continue

        # the same packet can still show up twice; drop exact repeats
        flow = (src, sport, dst, dport)
        dedup = (flow, seq, len(payload))
        if seen.get(dedup, 0) > now - 2:
            stats["dup"] += 1
            continue
        seen[dedup] = now
        if len(seen) > 20000:
            seen = {k: v for k, v in seen.items() if v > now - 2}

        buf = streams.get(flow, b"") + payload
        while len(buf) >= 20:
            if buf[0] != 1:
                # resync: find the next plausible Diameter header
                nxt = buf.find(b"\x01", 1)
                if nxt < 0:
                    buf = b""
                    break
                buf = buf[nxt:]
                continue
            length = int.from_bytes(buf[1:4], "big")
            if length < 20 or length > 65535:
                buf = buf[1:]
                continue
            if len(buf) < length:
                break
            msg, buf = buf[:length], buf[length:]
            try:
                ev = diameter_parse(msg)
            except Exception as e:
                log("parse: %r" % e)
                continue
            if not ev:
                continue
            ev["ts"] = now
            ev["src"] = src
            ev["dst"] = dst
            # Origin-Host names the sender authoritatively - no IP map needed
            origin = ev.get("origin") or ""
            ev["node"] = origin.split(".")[0] if origin else src
            stats["msg"] += 1
            try:
                out.sendto(json.dumps(ev).encode(), dest)
            except OSError as e:
                log("send: %s" % e)
        streams[flow] = buf[-1 << 20:] if len(buf) > (1 << 20) else buf

        if now - last > 30:
            last = now
            log("sniffer: messages=%d dup=%d flows=%d"
                % (stats["msg"], stats["dup"], len(streams)))


# ---------------------------------------------------------------------------

ROLES = {"collector": role_collector, "sniffer": role_sniffer}

if __name__ == "__main__":
    role = sys.argv[1] if len(sys.argv) > 1 else ""
    if role not in ROLES:
        log("usage: trace.py {%s}" % "|".join(ROLES))
        sys.exit(2)
    ROLES[role]()
