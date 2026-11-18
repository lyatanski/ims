#!/usr/bin/env python3
"""The verdict of a soak run (doc/test-plan.md, L6).

Two checks over what Prometheus scraped during the run, plus the IPsec SA
counts sample.sh wrote:

  * trend: nothing grows while the load is steady. The first WARMUP of the
    window is dropped (pools filling, the first calls), and the rest is cut
    into quarters. Memory fails when the median of the last quarter exceeds
    the first quarter's by more than REL and FLOOR both. A count fails when
    the peak of the last quarter exceeds the peak of the first: with a fixed
    number of call pairs the peak is fixed too, unless something is left
    behind.
  * zero at the end: once the run has de-registered and torn its PDN
    connections down, every session, dialog, binding and SA is gone.

Prints a table, appends it to $GITHUB_STEP_SUMMARY when that is set, writes
the series as CSV, and exits 1 when a check failed.
"""
import argparse
import csv
import json
import os
import statistics
import sys
import urllib.parse
import urllib.request

# The nodes on the call path, by compose service. The monitoring stack is left
# out: Prometheus and Loki grow by design.
NODES = "pcscf|icscf|scscf|tas|redis|hss|pcrf|smf|upf|ocs"

# (label, query, kind): kind "bytes" is checked on medians, "count" on peaks.
TREND = [
    ("RSS", f'container_memory_rss{{name=~".+-({NODES})-[0-9]+"}}', "bytes"),
    ("shm used", "kamailio_shmem_real_used_size", "bytes"),
    ("dialogs", "kamailio_dialog_ng_active", "count"),
    ("Ro sessions", "kamailio_ims_charging_active_ro_sessions", "count"),
    ("Rx media sessions", "kamailio_ims_qos_active_media_rx_sessions", "count"),
    ("Rx registration sessions", "kamailio_ims_qos_active_registration_rx_sessions", "count"),
    ("P-CSCF contacts", "kamailio_ims_usrloc_pcscf_registered_contacts", "count"),
    ("S-CSCF contacts", "kamailio_ims_usrloc_scscf_active_contacts", "count"),
    ("bearers", "bearers_active", "count"),
]

# Everything here is per call or per registration, so 0 once the run is over.
ZERO = [
    ("dialogs", "kamailio_dialog_ng_active"),
    ("Ro sessions", "kamailio_ims_charging_active_ro_sessions"),
    ("Rx media sessions", "kamailio_ims_qos_active_media_rx_sessions"),
    ("Rx registration sessions", "kamailio_ims_qos_active_registration_rx_sessions"),
    ("P-CSCF contacts", "kamailio_ims_usrloc_pcscf_registered_contacts"),
    ("S-CSCF contacts", "kamailio_ims_usrloc_scscf_active_contacts"),
    ("bearers", "bearers_active"),
    ("GTP-C sessions", "gtp2_sessions_active"),
    ("PFCP sessions", "pfcp_sessions_active"),
]


def query(prom, path, **params):
    url = f"{prom}/api/v1/{path}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(f"{url}: {body}")
    return body["data"]["result"]


def where(metric):
    """The node a series belongs to: the compose service for cAdvisor's
    container name (ims-scscf-1 -> scscf), the scrape job otherwise."""
    name = metric.get("name")
    if name:
        return name.split("-", 1)[-1].rsplit("-", 1)[0]
    return metric.get("job", "?")


def human(v, kind):
    if kind == "bytes":
        return f"{v / 2**20:.1f} MiB"
    return f"{v:g}"


def quarters(samples, warmup):
    """The first and last quarter of the samples past the warm-up."""
    if not samples:
        return [], []
    t0, t1 = samples[0][0], samples[-1][0]
    rest = [s for s in samples if s[0] >= t0 + (t1 - t0) * warmup]
    q = len(rest) // 4
    if q < 2:
        return [], []
    return [v for _, v in rest[:q]], [v for _, v in rest[-q:]]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--prom", required=True, help="Prometheus base URL")
    ap.add_argument("--start", type=float, required=True, help="load start, epoch s")
    ap.add_argument("--end", type=float, required=True, help="load end, epoch s")
    ap.add_argument("--sa", help="sample.sh's CSV")
    ap.add_argument("--csv", help="write the series here")
    ap.add_argument("--step", type=int, default=30, help="query step, s")
    ap.add_argument("--warmup", type=float, default=0.2, help="fraction of the window dropped")
    ap.add_argument("--rel", type=float, default=0.03, help="memory growth allowed, fraction")
    ap.add_argument("--floor", type=float, default=4, help="memory growth allowed, MiB")
    a = ap.parse_args()

    rows, failed, dump = [], False, []

    # ---- trend ----
    for label, q, kind in TREND:
        res = query(a.prom, "query_range", query=q, start=a.start, end=a.end, step=a.step)
        if not res:
            rows.append((label, "-", "-", "-", "no data"))
            continue
        for s in sorted(res, key=lambda s: where(s["metric"])):
            node = where(s["metric"])
            samples = [(float(t), float(v)) for t, v in s["values"]]
            dump += [(t, f"{label} {node}", v) for t, v in samples]
            first, last = quarters(samples, a.warmup)
            if not first:
                rows.append((f"{label} {node}", "-", "-", "-", "too few samples"))
                continue
            if kind == "bytes":
                f, l = statistics.median(first), statistics.median(last)
                bad = l - f > max(a.rel * f, a.floor * 2**20)
            else:
                f, l = max(first), max(last)
                bad = l > f
            failed |= bad
            rows.append((f"{label} {node}", human(f, kind), human(l, kind),
                         human(l - f, kind), "**GROWING**" if bad else "flat"))

    # ---- SAs: trend over the samples, then the last one at the end ----
    sa = []
    if a.sa and os.path.exists(a.sa):
        with open(a.sa) as fh:
            sa = [(float(r["time"]), float(r["sad"])) for r in csv.DictReader(fh) if r["sad"]]
        dump += [(t, "SAs pcscf", v) for t, v in sa]
        first, last = quarters([s for s in sa if a.start <= s[0] <= a.end], a.warmup)
        if first:
            bad = max(last) > max(first)
            failed |= bad
            rows.append(("SAs pcscf", f"{max(first):g}", f"{max(last):g}",
                         f"{max(last) - max(first):g}", "**GROWING**" if bad else "flat"))

    # ---- zero at the end ----
    zrows = []
    for label, q in ZERO:
        for s in query(a.prom, "query", query=q):
            v = float(s["value"][1])
            bad = v != 0
            failed |= bad
            zrows.append((f"{label} {where(s['metric'])}", f"{v:g}", "**LEFT OVER**" if bad else "0"))
    if sa:
        v = sa[-1][1]
        failed |= v != 0
        zrows.append(("SAs pcscf", f"{v:g}", "**LEFT OVER**" if v else "0"))

    out = [f"### Soak: {'FAILED' if failed else 'passed'}", "",
           f"Load window {(a.end - a.start) / 60:.0f} min, first {a.warmup:.0%} "
           f"dropped, first quarter against last.", "",
           "| Series | First quarter | Last quarter | Change | |", "|---|---|---|---|---|"]
    out += [f"| {' | '.join(r)} |" for r in rows]
    out += ["", "After the run:", "", "| Series | Value | |", "|---|---|---|"]
    out += [f"| {' | '.join(r)} |" for r in zrows]
    text = "\n".join(out) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(text)

    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["time", "series", "value"])
            w.writerows(dump)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
