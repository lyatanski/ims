local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local ds = 'prometheus';

local stat(title, expr, x, y, w, h, unit=null) =
  g.panel.stat.new(title)
  + g.panel.stat.queryOptions.withDatasource('prometheus', ds)
  + g.panel.stat.queryOptions.withTargets([g.query.prometheus.new(ds, expr)])
  + g.panel.stat.options.withGraphMode('area')
  + g.panel.stat.panelOptions.withGridPos(h=h, w=w, x=x, y=y)
  + if unit == null then {} else g.panel.stat.standardOptions.withUnit(unit);

local gauge(title, expr, x, y) =
  g.panel.gauge.new(title)
  + g.panel.gauge.queryOptions.withDatasource('prometheus', ds)
  + g.panel.gauge.queryOptions.withTargets([g.query.prometheus.new(ds, expr)])
  + g.panel.gauge.panelOptions.withGridPos(h=5, w=3, x=x, y=y);

local tsTarget(reason, legend) =
  g.query.prometheus.new(ds, 'rtpengine_closed_sessions_total{reason="%s", job="$job", instance="$instance"}' % reason)
  + g.query.prometheus.withLegendFormat(legend);

g.dashboard.new('RTP')
+ g.dashboard.withDescription('A general view of RTPEngine.')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withRefresh('5s')
+ g.dashboard.withPanels([
  gauge('Foreign Sessions',     'rtpengine_sessions{type="foreign", job="$job", instance="$instance"}', 0, 0),
  gauge('Own Sessions',         'rtpengine_sessions{type="own", job="$job", instance="$instance"}',     3, 0),
  gauge('Transcoding Sessions', 'rtpengine_transcoded_media{job="$job", instance="$instance"}',         6, 0),

  g.panel.timeSeries.new('Total Closed Sessions')
  + g.panel.timeSeries.queryOptions.withDatasource('prometheus', ds)
  + g.panel.timeSeries.queryOptions.withTargets([
    tsTarget('rejected',         'Rejected'),
    tsTarget('timeout',          'Timeout'),
    tsTarget('silent_timeout',   'Silent Timeout'),
    tsTarget('final_timeout',    'Final Timeout'),
    tsTarget('offer_timeout',    'Offer Timeout'),
    tsTarget('terminated',       'Terminated'),
    tsTarget('force_terminated', 'Force Timeout'),
  ])
  + g.panel.timeSeries.panelOptions.withGridPos(h=8, w=24, x=0, y=5),

  stat('Uptime',                'rtpengine_uptime_seconds{job="$job", instance="$instance"}',            10, 0,  7, 5, 's'),
  stat('Total sessions',        'rtpengine_sessions_total{job="$job", instance="$instance"}',            17, 0,  7, 5),
  stat('Total Relayed Packets', 'rtpengine_packets_total{type="userspace"}',                             0,  13, 6, 5),
  stat('Total Relayed Bytes',   'rtpengine_bytes_total{type="userspace"}',                               6,  13, 4, 5, 'decbytes'),
  stat('Total Relayed Errors',  'rtpengine_packet_errors_total{type="userspace"}',                       10, 13, 6, 5),
  stat('Zero packet streams',   'rtpengine_zero_packet_streams_total{job="$job", instance="$instance"}', 16, 13, 4, 5),
  stat('Total 1-way streams',   'rtpengine_one_way_sessions_total{job="$job", instance="$instance"}',    20, 13, 4, 5),
])
