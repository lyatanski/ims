local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local ds = 'prometheus';

g.dashboard.new('IMS')
+ g.dashboard.withDescription('IMS overview')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withRefresh('5s')
+ g.dashboard.withPanels([
    g.panel.stat.new('registrations')
    + g.panel.stat.panelOptions.withGridPos(h=6, w=6, x=0, y=0)
    + g.panel.stat.queryOptions.withTargets([
      g.query.prometheus.new(ds, 'kamailio_ims_registrar_scscf_accepted_regs')
      ]),
    g.panel.stat.new('calls')
    + g.panel.stat.panelOptions.withGridPos(h=6, w=6, x=6, y=0)
    + g.panel.stat.queryOptions.withTargets([
      g.query.prometheus.new(ds, 'kamailio_dialog_ng_active{job="scscf"}')
      ]),
    g.panel.stat.new('failed')
    + g.panel.stat.panelOptions.withGridPos(h=6, w=6, x=12, y=0)
    + g.panel.stat.queryOptions.withTargets([
      g.query.prometheus.new(ds, 'kamailio_ims_registrar_scscf_rejected_regs')
      ]),
])
