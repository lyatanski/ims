# Monitoring

The following values should be monitored:
- Health of the CSCFs (Node graph?)

- Active users in the system.
Thees should be monitored by `kamailio_ims_usrloc_scscf_active_contacts`.
`kamailio_ims_registrar_scscf_accepted_regs` could be misleading as the registration could expire.

- registration success?
- registrations/subscriptions for reg state ratio?

- Load on the system by active sessions.
`kamailio_dialog_ng_active` could be used to track active dialogs?

- the number of billed calls (ratio active/billed?)

- rejected sessions (calls)
  - by billing?
  - blocked?


## RTPEngine Overview
https://grafana.com/grafana/dashboards/22110-rtpengine-overview/
