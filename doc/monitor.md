# Monitoring — IMS KPIs (3GPP TS 32.454)

The `IMS KPI (3GPP TS 32.454)` Grafana dashboard (`ims.jsonnet` in `monitor.yml`)
presents IMS Key Performance Indicators **aligned with 3GPP TS 32.454**; what it
covers, and where it deviates, is listed under [Conformance](#conformance-to-ts-32454). It
reuses native Kamailio `xhttp_prom` statistics wherever possible and adds a small
set of custom S-CSCF counters for the session KPIs that cannot be derived from
the built-in statistics.

All statistics are exported by the `xhttp_prom` module (`xhttp_prom_stats "all"`,
see `images/kamailio/cscf/monitor.cfg`) on TCP `:9090`, scraped by Prometheus as
jobs `pcscf`, `icscf`, `scscf`. Metric names follow `kamailio_<group>_<stat>`
(`:` and `-` become `_`).

## Why custom counters are needed

TS 32.454 session KPIs are built from SIP session-establishment counts. The
S-CSCF is a **stateful (`tm`) proxy**, and Kamailio's `tm` module does **not**
export transaction counters through the statistics framework (only via the
`tm.stats` RPC), so `2xx/4xx/5xx` transaction outcomes are not available as
Prometheus metrics. The `sl` reply counters exist but, on a stateful proxy, they
only see locally generated stateless replies — not the relayed INVITE responses.

We therefore add custom metrics, declared in `monitor.cfg` and incremented
in `serving.cfg`. They are side-effect-free counter/histogram updates guarded so
that a missing dialog variable can never disturb call processing (a KPI sample is
just skipped or labelled `dir="na"`):

| Metric | Type | Labels | Incremented on |
|--------|------|--------|----------------|
| `kamailio_ims_session_setup_attempts_total` | counter | `dir` | initial INVITE (orig in `MORIG`, term in `MTERM`); a call whose both legs this S-CSCF serves is counted once, as `orig` |
| `kamailio_ims_session_setup_success_total`  | counter | `dir` | first `180` or `2xx` to the INVITE, once per session (TS 32.409 4.1.2.2) |
| `kamailio_ims_session_setup_failure_total`  | counter | `dir`,`code` | `>=300` final response with no `180` before it, including the 402 / 500 the S-CSCF answers itself when charging refuses the call |
| `kamailio_ims_session_setup_duration`       | histogram (ms) | `dir` | INVITE→first `180` or `2xx` elapsed time |
| `kamailio_ims_registration_initial_{success,failure}_total` | counter | | initial REGISTER (identity not registered), `route[SAA]` / `route[MAA]` |
| `kamailio_ims_registration_re_{success,failure}_total` | counter | | REGISTER with Expires > 0 for an identity that is registered already |

`dir` is `orig`/`term`; setup direction and start time are carried between the
request and reply routes in dialog variables (`$dlg_var(kpi*)`).

## KPI → metric mapping

### Accessibility — Registration (Initial Registration Success Rate)

Custom counters on the S-CSCF, incremented in `route[SAA]` and `route[MAA]`
(`serving.cfg`) for a REGISTER of an identity that is not registered yet.

```promql
# Initial Registration Success Rate (%)
100 * sum(increase(kamailio_ims_registration_initial_success_total{job="scscf"}[$__range]))
    / ( sum(increase(kamailio_ims_registration_initial_success_total{job="scscf"}[$__range]))
      + sum(increase(kamailio_ims_registration_initial_failure_total{job="scscf"}[$__range])) )
```

A re-registration and a de-registration are not counted: the `ims_registrar_scscf`
counters (`accepted_regs`, `rejected_regs`) count them, so those read 2 for a UE
that registers and leaves. A failure is a Cx answer that does not assign the
S-CSCF (SAA) or a failed MAR; the 401 auth-challenge leg and a REGISTER the UE
fails to authenticate are not counted.

Re-registration Success Rate (5.1.5) is the same ratio over
`kamailio_ims_registration_re_{success,failure}_total`. A REGISTER with
`Expires: 0` is a de-registration and is in neither.

### Accessibility — Session Establishment (SESR, SENSR)

Custom counters on the S-CSCF. TS 32.454 computes both ratios for the
originating and the terminating side **separately**, because a session summed
over both sides counts twice (Annex A.3). The dashboard has one panel per
`dir`; the `na` bucket (no dialog variable) stays out of both.

```promql
# SESR (%), per side: first 180 or 2xx over attempts
100 * sum(increase(kamailio_ims_session_setup_success_total{job="scscf", dir="orig"}[$__range]))
    / sum(increase(kamailio_ims_session_setup_attempts_total{job="scscf", dir="orig"}[$__range]))

# SENSR (%), per side: the failures of the user are added to the numerator
100 * ( sum(increase(kamailio_ims_session_setup_success_total{job="scscf", dir="orig"}[$__range]))
      + sum(increase(kamailio_ims_session_setup_failure_total{job="scscf", dir="orig", code=~"404|484|486|487|600"}[$__range])) )
    / sum(increase(kamailio_ims_session_setup_attempts_total{job="scscf", dir="orig"}[$__range]))
```

A session counts as established at its first `180` or `2xx` (TS 32.409 4.1.2.2:
the two are disjoint, so each session counts once), so a call that rings and is
then cancelled is a success; a `CANCEL` before the first `180` ends in `487` and
is a failure. SENSR (5.1.9) adds to the numerator the failures the spec blames
on the user: `486`, `600`, `404`, `484` and the release before ringing (`487`).
`480` and `603` are network failures here, as in the spec.

### Accessibility — Session Setup Time (latency)

Custom histogram (milliseconds), INVITE to the first `180` or `2xx` (TS 32.409
4.1.2.6), so it is the time to ring, not to answer. It is not split per media
name.

```promql
# mean setup time (ms)
sum(increase(kamailio_ims_session_setup_duration_sum{job="scscf"}[$__range]))
/ sum(increase(kamailio_ims_session_setup_duration_count{job="scscf"}[$__range]))

# p95 / p99 setup time (ms)
histogram_quantile(0.95, sum by (le) (rate(kamailio_ims_session_setup_duration_bucket{job="scscf"}[$__rate_interval])))
```

The dashboard also shows the **Diameter control-plane latency** that contributes
to setup/registration time, reused from native stats:
`ims_registrar_scscf_sar_avg_response_time` (Cx SAR),
`ims_auth_mar_avg_response_time` (Cx MAR),
`ims_charging_ccr_avg_response_time` (Ro CCR) and the I-CSCF UAR latency
(`ims_icscf_uar_replies_response_time / …_received`).

### Retainability — IMS Session Drop Rate

`dialog_ng` lifecycle counters and the `ims_charging` kill counter on the S-CSCF.

```promql
# Session Drop Rate (%) — sessions the network ended / sessions established
100 * ( sum(increase(kamailio_ims_charging_killed_calls{job="scscf"}[$__range]))
      + sum(increase(kamailio_dialog_ng_expired{job="scscf"}[$__range])) )
    / sum(increase(kamailio_ims_session_setup_success_total{job="scscf"}[$__range]))
```

A call the S-CSCF kills for lack of credit ends with a BYE, so `dialog_ng_expired`
(dialogs the dialog timer ended, no BYE seen) never counts it; `killed_calls`
does. The denominator is the established sessions (TS 32.454 5.2.1):
`dialog_ng_processed` also counts the setups that never got a `180`. Patch 0045
keeps an early dialog that times out out of `dialog_ng_expired`, which would
count a call that never rang as dropped. `dialog_ng_active`/`dialog_ng_early` give
the current confirmed/early session counts.

### Utilization — Registered base

Reused: `ims_usrloc_scscf` / `ims_usrloc_pcscf` gauges.

- `kamailio_ims_usrloc_scscf_active_impus` — IMPU records held (S-CSCF); a de-registered IMPU stays, unregistered, so this is not the registered count
- `kamailio_ims_usrloc_scscf_active_contacts` — registered contacts (S-CSCF), the registered base
- `kamailio_ims_usrloc_scscf_active_subscriptions` — reg-event subscriptions held, until they expire
- `kamailio_ims_usrloc_pcscf_registered_contacts` — registered contacts (P-CSCF)

### Charging — Ro (TS 32.299)

Reused: `ims_charging` counters/gauges (populated when the Ro/Rf peer is up).

- `kamailio_ims_charging_active_ro_sessions` — one per call leg that is up
- `kamailio_ims_charging_initial_ccrs` / `…_successful_initial_ccrs`
- `kamailio_ims_charging_killed_calls` (calls dropped for lack of credit)

### Element health — Diameter (Cx / Ro)

Reused: I-CSCF and S-CSCF Diameter counters.

- `kamailio_ims_icscf_uar_replies_received` / `…_lir_replies_received`
- `kamailio_ims_auth_mar_timeouts` (Cx MAR), `kamailio_ims_registrar_scscf_sar_timeouts` (Cx SAR),
  `kamailio_ims_charging_ccr_timeouts` (Ro CCR) — non-zero timeouts turn the panel red.

## Notes / caveats

- Percentage KPIs show *No data* when idle (no traffic in the selected range)
  rather than a misleading `0%`.
- The windowed Diameter round-trip
  (`rate(…_replies_response_time) / rate(…_replies_received)`) is `0/0` — i.e.
  `NaN` — while a leg is idle. A time series simply breaks the line there, but a
  single-value chip prints `NaN`, so the architecture canvas filters the
  denominator (`… / (rate(…_replies_received) > 0)`) to drop the sample and falls
  back with `or` to the module's own lifetime `…_avg_response_time`.
- Session KPIs are measured at the **S-CSCF**. The spec has the session
  counters at the P-CSCF (`SC.AttSessionOrig`) and the P-/I-CSCF
  (`SC.AttSessionTerm`) and computes the KPI "by I-CSCF" or "by P-CSCF", with
  roamer scoping that follows from the node; only registration is S-CSCF
  specific. Here `dir=orig` is a session that starts at a UE of this network and
  `dir=term` one that arrives from another network; a call between two users of
  this S-CSCF is one session, counted as `orig`.
- Setup-time samples are in **milliseconds** (Kamailio config integer math);
  the panels are configured with the `ms` unit.

## Conformance to TS 32.454

| § | KPI | State |
|---|-----|-------|
| 5.1.1 | Initial registration success rate | done (S-CSCF) |
| 5.1.2 | Session setup time (mean) | done, not per media name |
| 5.1.3 | SESR | done, per side |
| 5.1.4 | Third-party registration success rate | **not supported**: the REGISTER to the AS and its answer are in `ims_isc`, which exports no counter |
| 5.1.5 | Re-registration success rate | done (S-CSCF) |
| 5.1.6 / 5.1.7 | Setup time, IMS- / CS-originated | not applicable: counted at the MGCF, which this stack has none of |
| 5.1.8 | Immediate messaging success rate | **not supported**: no MESSAGE counters |
| 5.1.9 | SENSR | done, per side |
| 5.2.1 | Session drop rate | done |
| 5.3.1 | Mean session utilization | **not supported**: the spec leaves *Capacity* undefined (FFS) and TS 32.409 has no capacity counter |

Deviations and local choices:

- The measurement point is the S-CSCF (see Notes).
- SENSR reads `dir`-split counters. TS 32.454 5.1.9 names
  `SC.RelBeforeRingOrig/Term` and `SC.FailSessionOrig/Term`, which TS 32.409 only
  defines without the side split; the `dir` label is our reading of it.
- The 95/99 % and 2/5 % thresholds are ours. The p95/p99 setup time, the Diameter
  latency, charging and registered-base panels are extras and not 32.454 KPIs.
