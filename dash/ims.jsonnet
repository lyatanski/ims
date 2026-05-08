local prometheus = { type: 'prometheus', uid: 'prometheus' };

local panel(id, title, gridPos, expr, extra={}) = {
  id: id,
  title: title,
  type: 'stat',
  datasource: prometheus,
  gridPos: gridPos,
  targets: [{
    refId: 'A',
    datasource: prometheus,
    expr: expr,
    range: true,
  }],
} + extra;

{
  title: 'ims',
  uid: 'ad4fzvg',
  description: 'IMS overview',
  time: { from: 'now-6h', to: 'now' },
  panels: [
    panel(1, 'registrations', { h: 6, w: 6, x: 0, y: 0 },  'kamailio_ims_registrar_scscf_accepted_regs'),
    panel(2, 'failed',        { h: 6, w: 6, x: 0, y: 6 },  'kamailio_ims_registrar_scscf_rejected_regs'),
    panel(3, 'calls',         { h: 12, w: 7, x: 6, y: 0 }, 'kamailio_dialog_ng_active{job="scscf"}'),
  ],
}
