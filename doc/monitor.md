# Monitoring — IMS KPIs (3GPP TS 32.454)

The `IMS KPI (3GPP TS 32.454)` Grafana dashboard (`ims.jsonnet` in `monitor.yml`)
presents the IMS Key Performance Indicators defined by **3GPP TS 32.454**. It
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

We therefore add four custom metrics, declared in `monitor.cfg` and incremented
in `serving.cfg`. They are side-effect-free counter/histogram updates guarded so
that a missing dialog variable can never disturb call processing (a KPI sample is
just skipped or labelled `dir="na"`):

| Metric | Type | Labels | Incremented on |
|--------|------|--------|----------------|
| `kamailio_ims_session_setup_attempts_total` | counter | `dir` | initial INVITE (orig in `MORIG`, term in `MTERM`) |
| `kamailio_ims_session_setup_success_total`  | counter | `dir` | first `2xx` final response to the INVITE |
| `kamailio_ims_session_setup_failure_total`  | counter | `dir`,`code` | `>=300` final response to the INVITE |
| `kamailio_ims_session_setup_duration`       | histogram (ms) | `dir` | INVITE→`2xx` elapsed time |

`dir` is `orig`/`term`; setup direction and start time are carried between the
request and reply routes in dialog variables (`$dlg_var(kpi*)`).

## KPI → metric mapping

### Accessibility — Registration (Initial Registration Success Rate)

Reused: `ims_registrar_scscf` counters on the S-CSCF.

```promql
# Registration Success Rate (%)
100 * sum(increase(kamailio_ims_registrar_scscf_accepted_regs{job="scscf"}[$__range]))
    / ( sum(increase(kamailio_ims_registrar_scscf_accepted_regs{job="scscf"}[$__range]))
      + sum(increase(kamailio_ims_registrar_scscf_rejected_regs{job="scscf"}[$__range])) )
```

Approximation: `accepted_regs`/`rejected_regs` count all accepted/rejected
registrations (initial, re-registration and de-registration), so this is a close
proxy of the TS 32.454 *Initial* Registration Success Rate rather than an exact
initial-only figure. The 401 auth-challenge leg is not counted as a rejection.

### Accessibility — Session Establishment (SESR)

Custom counters on the S-CSCF.

```promql
# Session Establishment Success Rate (%)
100 * sum(increase(kamailio_ims_session_setup_success_total{job="scscf"}[$__range]))
    / sum(increase(kamailio_ims_session_setup_attempts_total{job="scscf"}[$__range]))

# Session Establishment Network Success Rate (%) — excludes UE/user-caused failures
100 * sum(increase(kamailio_ims_session_setup_success_total{job="scscf"}[$__range]))
    / ( sum(increase(kamailio_ims_session_setup_attempts_total{job="scscf"}[$__range]))
      - sum(increase(kamailio_ims_session_setup_failure_total{job="scscf", code=~"404|480|484|486|487|600|603"}[$__range])) )
```

The network success rate follows TS 32.454 by removing user-caused outcomes from
the denominator: `404` (user not found), `484` (address incomplete),
`480/486/600/603` (unavailable/busy/decline), `487` (released before answer).

### Accessibility — Session Setup Time (latency)

Custom histogram (milliseconds).

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

Reused: `ims_dialog` (`dialog_ng`) lifecycle counters on the S-CSCF.

```promql
# Session Drop Rate (%) — abnormally killed dialogs / processed dialogs
100 * sum(increase(kamailio_dialog_ng_expired{job="scscf"}[$__range]))
    / sum(increase(kamailio_dialog_ng_processed{job="scscf"}[$__range]))
```

`dialog_ng_expired` counts dialogs forcibly killed by the dialog timer (i.e. no
BYE seen — an abnormal release); `dialog_ng_processed` is the number of processed
dialogs. `dialog_ng_active`/`dialog_ng_early` give the current confirmed/early
session counts. A precise "abnormal release of *established* sessions only"
figure would need a dialog end-event hook.

### Utilization — Registered base

Reused: `ims_usrloc_scscf` / `ims_usrloc_pcscf` gauges.

- `kamailio_ims_usrloc_scscf_active_impus` — registered IMPUs (S-CSCF)
- `kamailio_ims_usrloc_scscf_active_contacts` — registered contacts (S-CSCF)
- `kamailio_ims_usrloc_scscf_active_subscriptions` — reg-event subscriptions
- `kamailio_ims_usrloc_pcscf_registered_contacts` — registered contacts (P-CSCF)

### Charging — Ro (TS 32.299)

Reused: `ims_charging` counters/gauges (populated when the Ro/Rf peer is up).

- `kamailio_ims_charging_active_ro_sessions`
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
- Session KPIs are measured at the **S-CSCF**, consistent with TS 32.454's
  S-CSCF-centric session counters. Both originating and terminating directions
  are captured (`dir` label).
- Setup-time samples are in **milliseconds** (Kamailio config integer math);
  the panels are configured with the `ms` unit.
