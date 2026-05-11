local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local ds = 'loki';
local var = g.dashboard.variable;

g.dashboard.new('logs')
+ g.dashboard.withDescription('logs overview')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withRefresh('5s')
+ g.dashboard.withVariables([
  var.query.new('container', 'label_values(container)')
  + var.query.withDatasource('loki', ds)
  + var.query.generalOptions.withLabel('Container')
  + var.query.refresh.onLoad()
  + var.query.withSort(5)
  + var.query.selectionOptions.withMulti()
  + var.query.selectionOptions.withIncludeAll(customAllValue='.+'),
  var.textbox.new('search')
  + var.textbox.generalOptions.withLabel('Search'),
])
+ g.dashboard.withPanels([
  g.panel.logs.new('')
  + g.panel.logs.panelOptions.withGridPos(h=22, w=24, x=0, y=0)
  + g.panel.logs.panelOptions.withTransparent()
  + g.panel.logs.queryOptions.withDatasource('loki', ds)
  + g.panel.logs.queryOptions.withTargets([
    g.query.loki.new(ds, '{container=~"$container"} |~ "(?i)$search"')
    + g.query.loki.withRefId('A'),
  ]),
])
