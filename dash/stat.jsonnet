local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local ds = 'prometheus';

local stat(title, expr, pos, unit=null) =
  g.panel.stat.new(title)
  + g.panel.stat.queryOptions.withDatasource('prometheus', ds)
  + g.panel.stat.queryOptions.withTargets([g.query.prometheus.new(ds, expr)])
  + g.panel.stat.panelOptions.withGridPos(pos.h, pos.w, pos.x, pos.y)
  + g.panel.stat.panelOptions.withTransparent()
  + if unit == null then {} else g.panel.stat.standardOptions.withUnit(unit);

local ts(title, expr, pos, unit) =
  g.panel.timeSeries.new(title)
  + g.panel.timeSeries.queryOptions.withDatasource('prometheus', ds)
  + g.panel.timeSeries.queryOptions.withTargets([
      g.query.prometheus.new(ds, expr)
      + g.query.prometheus.withLegendFormat('{{name}}')
    ])
  + g.panel.timeSeries.panelOptions.withGridPos(pos.h, pos.w, pos.x, pos.y)
  + g.panel.timeSeries.standardOptions.withUnit(unit);

g.dashboard.new('stat')
+ g.dashboard.withDescription('container resource monitoring')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withRefresh('5s')
+ g.dashboard.graphTooltip.withSharedCrosshair()
+ g.dashboard.withPanels([
  stat('Running containers', 'count(time() - container_last_seen{name!=\'\'} < 30)',              {h: 3, w: 8, x: 0,  y: 0}),
  stat('Total Mem Usage',    'sum(container_memory_usage_bytes{name!=\'\'})',                     {h: 3, w: 8, x: 8,  y: 0}, 'bytes'),
  stat('Total CPU Usage',    'sum(rate(container_cpu_user_seconds_total{name!=\'\'}[5m]) * 100)', {h: 3, w: 8, x: 16, y: 0}, 'percent')
  + g.panel.stat.standardOptions.withMin(0)
  + g.panel.stat.standardOptions.withMax(100),

  ts('CPU Usage',  'rate(container_cpu_user_seconds_total{name!=\'\'}[5m]) * 100',                {h: 7, w: 24, x: 0,  y: 3 }, 'percent'),
  ts('Mem Usage',  'container_memory_usage_bytes{name!=\'\'}',                                    {h: 7, w: 24, x: 0,  y: 10}, 'bytes'),
  ts('Network Rx', 'irate(container_network_receive_bytes_total{name!=\'\'}[5m])',                {h: 7, w: 12, x: 0,  y: 17}, 'Bps'),
  ts('Network Tx', 'irate(container_network_transmit_bytes_total{name!=\'\'}[5m])',               {h: 7, w: 12, x: 12, y: 17}, 'Bps'),
])
