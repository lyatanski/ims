'use strict'

// webshark UI: a paged packet list, the dissection tree, and the bytes. No
// framework and no build step - this file is what the browser runs.
//
// The list holds one screenful of DOM no matter how big the capture is: rows are
// recycled, and pages of PAGE frames are fetched when they scroll into view.
// sharkd caches the filter's match bitmap, so paging through a filtered capture
// costs one dissection per frame drawn, not one per page.
//
// Those rows draw two ways: the packet list, and Wireshark's flow graph - a
// column per address and an arrow per frame. Both read the same pages, so the
// header's List/Flow button is a repaint and nothing else.

const ROW = 20     // px per list row, matches --row in style.css
const FROW = 28    // ...and per flow row, matches --frow
const PAGE = 200   // frames per /api/frames call
const OVER = 8     // rows drawn above and below the viewport
const GUT = 144    // the flow view's time and frame-number gutter, matches .ft/.fnum
const LANE = [160, 400]  // node column: spread to fill the window, between these
const NODES = 40   // as many addresses as Wireshark's own flow graph draws

const $ = sel => document.querySelector(sel)

async function api(path, params, init) {
  const res = await fetch('/api/' + path + '?' + new URLSearchParams(params), init)
  const body = await res.json()
  if (body && body.err) throw new Error(body.err)
  return body
}

const S = {
  file: null, filter: '', cols: [], total: 0,
  vis: [],           // row.c indexes the list draws, in order
  ix: {},            // ...and the ones the flow view needs, by name
  view: 'list',
  count: 0,          // frames known to be in the current view
  end: true,         // ...and whether that is all of them
  pages: new Map(),  // page index -> rows, or the Promise fetching them
  selIdx: -1, want: 0,
  nodes: [], node: new Map(),  // flow view: addresses, in the order first seen
  overflow: false,  // ...and whether an address had to be left out of them
  addrs: 0,         // addresses in the whole capture, which is the server's count
  nodeW: LANE[0], width: 0,
  open: new Set(),   // expanded tree nodes by field name, kept across frames
  sources: [], src: 0, mark: null,
}

const list = $('#list'), canvas = $('#canvas'), hex = $('#hex')
let slots = []       // recycled row elements

const flowing = () => S.view === 'flow'
const rowH = () => flowing() ? FROW : ROW

function span(cls, text) {
  const el = document.createElement('span')
  if (cls) el.className = cls
  if (text) el.textContent = text
  return el
}

// ------------------------------------------------------------- packet list ---

function height() {
  // an unfiltered capture knows its length from `status`; a filtered one only
  // finds out when a page comes back short, so leave a page of room to scroll
  // into until then
  return (S.count + (S.end ? 0 : PAGE)) * rowH()
}

function rowAt(i) {
  // select() asks for the row before the selected one, so the first row asks for
  // index -1. There is no page -1 to fetch: the negative skip is dropped by the
  // server, page 0 comes back as its contents, and the length of it lands in
  // S.count as -PAGE + length - a negative count draws no rows at all.
  if (i < 0) return null
  const p = Math.floor(i / PAGE), page = S.pages.get(p)
  if (page === undefined) { fetchPage(p); return null }
  if (typeof page.then === 'function') return null
  return page[i - p * PAGE] || null
}

function fetchPage(p) {
  const req = api('frames', { f: S.file, filter: S.filter, skip: p * PAGE, limit: PAGE })
    .then(res => {
      S.pages.set(p, res.rows)
      nodes(res.rows)
      const seen = p * PAGE + res.rows.length
      if (S.filter) {
        S.count = Math.max(S.count, seen)
        if (res.end) { S.count = seen; S.end = true }
      }
      counter(); paint()
    })
    .catch(err => { S.pages.delete(p); note(err.message) })
  S.pages.set(p, req)
  return req
}

// A slot is built for the view that is current when it first appears; switching
// views throws the lot away, so the two shapes never have to convert into each
// other.
function slot(i) {
  while (slots.length <= i) {
    const el = document.createElement('div')
    if (flowing()) {
      el.className = 'frow'
      const label = span('fl')
      label.append(document.createElement('i'), span())
      const line = document.createElement('div')
      line.className = 'fa'
      line.append(label, span('fp a'), span('fp b'))
      el.append(span('ft'), span('fnum'), line)
    } else {
      el.className = 'row'
      for (const _ of S.cols) el.appendChild(span())
    }
    el.addEventListener('mousedown', () => {
      const i = +el.dataset.i
      if (i === S.selIdx) deselect(); else select(i)
    })
    canvas.appendChild(el)
    slots.push(el)
  }
  return slots[i]
}

let queued = false
function paint() {
  if (queued) return
  queued = true
  requestAnimationFrame(() => { queued = false; draw() })
}

function draw() {
  const H = rowH()
  if (flowing()) layout()
  canvas.style.height = height() + 'px'
  const last = S.count + (S.end ? 0 : PAGE)
  const first = Math.max(0, Math.floor(list.scrollTop / H) - OVER)
  const upto = Math.min(last, first + Math.ceil(list.clientHeight / H) + OVER * 2)

  let s = 0
  for (let i = first; i < upto; i++, s++) {
    const row = rowAt(i), el = slot(s)
    el.style.top = i * H + 'px'
    el.dataset.i = i
    el.hidden = false
    el.classList.toggle('sel', i === S.selIdx)
    el.classList.toggle('gap', !row)
    hue(el, row, i === S.selIdx)
    if (flowing()) arrow(el, row)
    else {
      const cells = el.children
      for (let c = 0; c < S.vis.length; c++) {
        cells[c].textContent = row ? (row.c[S.vis[c]] || '') : (c === 0 ? '…' : '')
      }
    }
  }
  for (; s < slots.length; s++) slots[s].hidden = true
}

function reveal(i) {
  const H = rowH()
  // the height the canvas is *about* to be drawn at: scrolling into a canvas that
  // has not been drawn yet - opening a link with a frame in it - clamps to 0
  canvas.style.height = height() + 'px'
  if (i * H < list.scrollTop) list.scrollTop = i * H
  const bottom = H + (i + 1) * H    // the sticky header owns the first row
  if (bottom - list.scrollTop > list.clientHeight) list.scrollTop = bottom - list.clientHeight
}

async function select(i) {
  let row = rowAt(i)
  if (!row) {
    // paging down or clicking into a page still in flight: wait for it rather
    // than making the keypress look ignored
    const pending = S.pages.get(Math.floor(i / PAGE))
    if (pending && typeof pending.then === 'function') { await pending; row = rowAt(i) }
    if (!row) return
  }
  S.selIdx = i
  S.want = row.n
  sync(); paint()

  const prev = rowAt(i - 1)
  const frame = await api('frame', { f: S.file, num: row.n, prev: prev ? prev.n : 0 })
    .catch(err => { note(err.message); return null })
  if (!frame || S.want !== row.n) return   // a faster click won
  show(frame)
}

function deselect() {
  S.selIdx = -1
  S.want = 0
  $('#viewer').classList.remove('picked')
  $('#tree').textContent = ''
  hex.textContent = ''
  $('#sources').textContent = ''
  $('#field').textContent = ''
  sync(); paint()
}

function move(delta) {
  const to = Math.max(0, Math.min(S.count - 1, (S.selIdx < 0 ? 0 : S.selIdx + delta)))
  reveal(to)
  select(to)
}

// ------------------------------------------------------------------ columns ---

// A row is every column sharkd sent, hidden ones included, so the flow view finds
// the addresses and the ports by column *format* rather than by position - and a
// sharkd configured differently, or not at all, still lines up. The ports are the
// two hidden columns the image adds (images/webshark/preferences); without them
// the diagram simply has no ports to label its arrows with.
function columns(st) {
  const info = st.column_info ||
    (st.columns || []).map(title => ({ title, format: '', visible: true }))
  S.vis = info.map((_, i) => i).filter(i => info[i].visible !== false)
  S.cols = S.vis.map(i => info[i].title)

  const at = (fmt, title) => {
    const i = info.findIndex(c => c.format === fmt)
    return i >= 0 ? i : info.findIndex(c => c.title === title)
  }
  S.ix = {
    time: at('%t', 'Time'), src: at('%s', 'Source'), dst: at('%d', 'Destination'),
    sport: at('%uS', 'SrcPort'), dport: at('%uD', 'DstPort'),
    proto: at('%p', 'Protocol'), info: at('%i', 'Info'),
  }
  // with no addresses to put in columns there is no diagram to offer
  $('#mode').hidden = S.ix.src < 0 || S.ix.dst < 0
  if ($('#mode').hidden) S.view = 'list'
}

const cell = (row, name) => (S.ix[name] >= 0 ? row.c[S.ix[name]] : '') || ''

// fixed widths for the columns Wireshark keeps narrow, the rest to the last one -
// which is Info, and wants everything it can get
const WIDE = {
  'No.': 76, Time: 112, Delta: 96, Source: 150,
  Destination: 150, Protocol: 76, Length: 64,
}
const INFO_MIN = 160  // below this the 1fr column would hit 0 and vanish

// The list's column titles. The flow view's header is the node columns, which
// only layout() knows the geometry of.
function head() {
  const cols = $('#cols')
  cols.textContent = ''
  cols.style.minWidth = ''
  canvas.style.minWidth = ''
  if (flowing()) return
  for (const title of S.cols) cols.appendChild(span('', title))
  $('#viewer').style.setProperty('--grid',
    S.cols.map((c, i) => i === S.cols.length - 1 ? '1fr' : (WIDE[c] || 110) + 'px').join(' '))
  // otherwise a narrow window shrinks the fixed columns' shared box below their
  // own total, and the overflow renders past #cols/canvas with no background to
  // paint it on - the header looks half-transparent and Info can hit 0 width
  const fixed = S.cols.slice(0, -1).reduce((sum, c) => sum + (WIDE[c] || 110), 0)
  const minWidth = fixed + INFO_MIN + 'px'
  cols.style.minWidth = minWidth
  canvas.style.minWidth = minWidth
}

// The views share the pages, the filter and the selection, so switching is a
// repaint - of rows built the other way, hence throwing the slots out.
function view(pick) {
  const top = Math.round(list.scrollTop / rowH())
  S.view = pick
  const button = $('#mode')
  button.classList.toggle('flow', flowing())   // the icon draws whichever view is on
  button.title = flowing()
    ? 'Sequence diagram (click for the packet list)'
    : 'Packet list (click for the sequence diagram)'
  $('#viewer').classList.toggle('flow', flowing())
  for (const el of slots) el.remove()
  slots = []
  unlane()
  head()
  warnFlow()
  canvas.style.height = height() + 'px'   // as in reveal(): rows of another height
  list.scrollTop = top * rowH()           // scroll to the same frame, not the same px
  sync(); paint()
  addresses()   // after the paint: the rows are worth more than the warning is
}

$('#mode').onclick = () => view(flowing() ? 'list' : 'flow')

// ----------------------------------------------------------- coloring rules ---

// Wireshark's coloring rules, which sharkd applies as it dissects: a frame comes
// back with the colours of the first rule that matched it, and its row is painted
// with them. The row only carries the pair - what light and dark each make of it
// is style.css's business.
//
// Two rows are left plain. The selected one keeps the selection colour, which has
// to stay the unmistakable thing on the list; a row whose page is still in flight
// has no colours to carry yet.
function hue(el, row, sel) {
  const on = !!(row && row.bg) && !sel
  el.classList.toggle('hue', on)
  if (on) {
    el.style.setProperty('--rbg', '#' + row.bg)
    el.style.setProperty('--rfg', '#' + row.fg)
  }
}

// -------------------------------------------------------- sequence diagram ---

// Wireshark's flow graph: a column per address, a row per frame, an arrow from
// the source's lifeline to the destination's. The columns are the addresses of the
// pages fetched so far - the capture is not read ahead to find the rest, so a
// column appears when a frame using it is first paged in, and the order is the
// order of the frames. Filter first and the diagram is the conversation.
function nodes(rows) {
  for (const row of rows) {
    for (const addr of [cell(row, 'src'), cell(row, 'dst')]) {
      if (!addr || S.node.has(addr)) continue
      if (S.nodes.length < NODES) { S.node.set(addr, S.nodes.length); S.nodes.push(addr) }
      else S.overflow = true
    }
  }
  warnFlow()
}

// Too many addresses for the diagram to draw them all: the frames using the ones
// past NODES keep their rows, as plain text rather than arrows (see arrow()), and a
// filter narrowing the capture down is the way back to a real diagram.
//
// Two things know about it. addresses() has asked the server for the whole
// capture's count, so the warning is up before a row that overflows is anywhere
// near the screen; S.overflow is the node list filling up as pages arrive, which is
// the backstop for what that count leaves out - the MAC of a frame with no IP.
function warnFlow() {
  const over = S.addrs > NODES
  $('#flowwarn').hidden = !(flowing() && (over || S.overflow))
  $('#flowmsg').textContent = over
    ? S.addrs + ' addresses, more than the ' + NODES + ' this diagram draws —'
    : 'More addresses than the ' + NODES + ' this diagram draws —'
}

// One pass over the capture, so it is worth doing once per file and filter and not
// on every switch into the view. It shares the capture's sharkd with the pages, and
// that answers one request at a time: on a big capture the count can hold a page up
// for a moment, which draws the placeholder rows a page in flight already draws.
let asked = ''
async function addresses() {
  if (!flowing() || !S.file) return
  const key = S.file + '\n' + S.filter
  if (asked === key) return
  asked = key
  const res = await api('addresses', { f: S.file, filter: S.filter }).catch(() => null)
  if (!res || asked !== key) return   // the filter moved on while this was out
  S.addrs = res.n
  warnFlow()
}

const lanes = []   // one lifeline element per node
let laid = ''      // the geometry the header and the lifelines were built for

function unlane() {
  for (const el of lanes) el.remove()
  lanes.length = 0
  laid = ''
}

const x = i => GUT + S.nodeW * i + (S.nodeW >> 1)

function layout() {
  const n = S.nodes.length
  const room = list.clientWidth - GUT - 12
  S.nodeW = Math.max(LANE[0], Math.min(LANE[1], n > 0 ? Math.floor(room / n) : LANE[0]))
  S.width = GUT + S.nodeW * n
  const sig = n + ':' + S.nodeW
  if (sig === laid) return   // no node came in, and the window is the size it was
  laid = sig

  unlane()
  // min, not width: a diagram narrower than the window still wants full-width rows
  // to highlight and a header band that reaches the end of it
  canvas.style.minWidth = S.width + 'px'
  const cols = $('#cols')
  cols.style.minWidth = S.width + 'px'
  cols.textContent = ''
  cols.append(span('ft', 'Time'), span('fnum', 'No.'))
  S.nodes.forEach((addr, i) => {
    const label = span('fnode', addr)
    label.style.left = (x(i) - (S.nodeW >> 1)) + 'px'
    label.style.width = S.nodeW + 'px'
    label.title = addr
    cols.appendChild(label)

    const life = document.createElement('div')
    life.className = 'life'
    life.style.left = x(i) + 'px'
    canvas.appendChild(life)
    lanes.push(life)
  })
}

// Wireshark labels an arrow with a comment the dissector registers for the flow
// graph, which the columns do not carry; Info is the closest thing to it, less the
// part the arrow itself already says.
const trim = info => info.replace(/^(Request|Status): /, '').replace(/\s*\|\s*$/, '').trim()

const SELF = 28    // px of stub for a frame addressed to where it came from

function arrow(el, row) {
  const time = el.children[0], num = el.children[1], line = el.children[2]
  const label = line.children[0], left = line.children[1], right = line.children[2]

  time.textContent = row ? cell(row, 'time') : '…'
  num.textContent = row ? row.n : ''
  line.hidden = !row
  if (!row) return

  const src = cell(row, 'src'), dst = cell(row, 'dst')
  const from = S.node.get(src), to = S.node.get(dst)
  let text = trim(cell(row, 'info'))

  if (from === undefined || to === undefined) {
    // an address past the node limit: the frame keeps its row, as a line of text
    // rather than an arrow, so a filtered set is never quietly short
    line.className = 'fa plain'
    line.style.left = GUT + 'px'
    line.style.width = Math.max(320, S.width - GUT) + 'px'
    text = [src, dst].filter(Boolean).join(' → ') + '   ' + text
    left.textContent = right.textContent = ''
  } else {
    const a = x(from), b = x(to), self = from === to
    const back = self || b < a     // a stub points back at the lifeline it left
    const sp = cell(row, 'sport'), dp = cell(row, 'dport')
    line.className = 'fa' + (back ? ' rev' : '') + (self ? ' self' : '') +
      (!self && sp && dp ? ' ports' : '')
    line.style.left = (self ? a : Math.min(a, b)) + 'px'
    line.style.width = (self ? SELF : Math.abs(b - a)) + 'px'
    // the ports go by which end of the line each is at, not which is the source
    left.textContent = self ? '' : (back ? dp : sp)
    right.textContent = self ? '' : (back ? sp : dp)
  }

  const proto = cell(row, 'proto')
  label.children[0].textContent = proto
  label.children[1].textContent = text
  label.title = (proto ? proto + ': ' : '') + cell(row, 'info')
}

// ------------------------------------------------------------------- detail ---

function show(frame) {
  S.sources = [{ name: 'Frame', bytes: frame.bytes || '' }, ...(frame.ds || [])]
  S.src = 0
  S.mark = null
  const tree = $('#tree')
  tree.textContent = ''
  tree.appendChild(build(frame.tree || []))
  tabs(); bytes()
  $('#field').textContent = ''
  // the panes are worth their space now - and taking it halves the list, so the
  // row this frame came from has to be put back on screen
  const opening = !$('#viewer').classList.contains('picked')
  $('#viewer').classList.add('picked')
  if (opening && S.selIdx >= 0) { reveal(S.selIdx); paint() }
}

// Children are built when a node is first expanded, so a frame with a few
// thousand fields costs only what is on screen.
function build(nodes) {
  const frag = document.createDocumentFragment()
  for (const n of nodes) {
    const el = document.createElement('div')
    el.className = 'n'
    el._n = n

    const label = document.createElement('span')
    label.className = 'l'
    const twisty = document.createElement('span')
    twisty.className = 't'
    twisty.textContent = n.n ? (S.open.has(key(n)) ? '▾' : '▸') : ''
    const text = document.createElement('span')
    text.textContent = n.l || ''
    if (n.g) text.classList.add('g')
    if (n.s === 'Warning' || n.s === 'Note') text.classList.add('warn')
    if (n.s === 'Error') text.classList.add('err')
    label.append(twisty, text)
    el.appendChild(label)

    if (n.n) {
      const kids = document.createElement('div')
      kids.className = 'kids'
      kids.hidden = !S.open.has(key(n))
      if (!kids.hidden) kids.appendChild(build(n.n))
      el.appendChild(kids)
    }
    frag.appendChild(el)
  }
  return frag
}

const key = n => n.fn || n.l || ''

function toggle(el) {
  const kids = el.querySelector(':scope > .kids')
  if (!kids) return
  const shown = !kids.hidden
  if (shown) S.open.delete(key(el._n))
  else {
    S.open.add(key(el._n))
    if (!kids.firstChild) kids.appendChild(build(el._n.n))
  }
  kids.hidden = shown
  el.querySelector(':scope > .l > .t').textContent = shown ? '▸' : '▾'
}

function pick(el) {
  for (const on of document.querySelectorAll('#tree .n.sel')) on.classList.remove('sel')
  el.classList.add('sel')
  const n = el._n
  S.mark = n.h || null
  const src = n.ds === undefined ? 0 : n.ds
  if (src !== S.src && src < S.sources.length) { S.src = src; tabs() }
  bytes(true)

  const field = $('#field')
  field.textContent = n.f || n.fn || ''
  field._filter = n.f || ''
  field.title = n.f ? 'Apply as filter' : ''
}

$('#tree').addEventListener('click', e => {
  const el = e.target.closest('.n')
  if (!el) return
  if (e.target.classList.contains('t')) toggle(el)
  else pick(el)
})
$('#tree').addEventListener('dblclick', e => {
  const el = e.target.closest('.n')
  if (el) toggle(el)
})
$('#field').addEventListener('click', () => {
  if ($('#field')._filter) filter($('#field')._filter)
})

// -------------------------------------------------------------------- bytes ---

function tabs() {
  const bar = $('#sources')
  bar.textContent = ''
  if (S.sources.length < 2) return          // nothing to choose between
  S.sources.forEach((src, i) => {
    const b = document.createElement('button')
    b.textContent = src.name || 'source ' + i
    b.className = i === S.src ? 'on' : ''
    b.onclick = () => { S.src = i; tabs(); bytes() }
    bar.appendChild(b)
  })
}

function decode(b64) {
  if (!b64) return new Uint8Array(0)
  const bin = atob(b64), out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, '0'))
const CHAR = Array.from({ length: 256 }, (_, i) => {
  if (i < 0x20 || i > 0x7e) return '.'
  return i === 60 ? '&lt;' : i === 62 ? '&gt;' : i === 38 ? '&amp;' : String.fromCharCode(i)
})

function bytes(scroll) {
  const data = decode((S.sources[S.src] || {}).bytes)
  const from = S.mark ? S.mark[0] : -1, to = S.mark ? S.mark[0] + S.mark[1] : -1
  const out = []
  for (let off = 0; off < data.length; off += 16) {
    let h = '', a = '', open = false
    for (let i = 0; i < 16; i++) {
      const p = off + i
      if (p >= data.length) {
        if (open) { h += '</b>'; a += '</b>'; open = false }
        h += i === 7 ? '    ' : '   '
        continue
      }
      const on = p >= from && p < to
      if (on && !open) { h += '<b>'; a += '<b>'; open = true }
      if (!on && open) { h += '</b>'; a += '</b>'; open = false }
      h += HEX[data[p]] + (i === 7 ? '  ' : ' ')
      a += CHAR[data[p]]
    }
    if (open) { h += '</b>'; a += '</b>' }
    out.push('<i>' + off.toString(16).padStart(4, '0') + '</i>  ' + h + ' ' + a)
  }
  hex.innerHTML = out.join('\n')
  if (scroll) hex.querySelector('b')?.scrollIntoView({ block: 'nearest' })
}

// ------------------------------------------------------------------- filter ---

async function filter(text) {
  text = (text || '').trim()
  $('#filter').value = text
  $('#spin').hidden = false
  try {
    if (text) {
      const check = await api('check', { f: S.file, filter: text }).catch(err => ({ ok: false, err: err.message }))
      if (!check.ok) { $('#filter').classList.add('bad'); note(check.err); return }
    }
    $('#filter').classList.remove('bad')
    note('')
    S.filter = text
    rewind()
    await fetchPage(0)   // the slow part: sharkd builds the whole-file match bitmap here
  } finally {
    $('#spin').hidden = true
  }
}

function rewind() {
  S.pages.clear()
  S.selIdx = -1
  S.count = S.filter ? 0 : S.total
  S.end = !S.filter
  S.nodes = []          // the node columns are the pages', and those are gone
  S.node.clear()
  S.overflow = false
  S.addrs = 0           // ...and the count was of the set the filter just replaced
  warnFlow()
  unlane()
  list.scrollTop = 0
  $('#tree').textContent = ''
  hex.textContent = ''
  $('#sources').textContent = ''
  $('#field').textContent = ''
  $('#viewer').classList.remove('picked')
  counter(); sync(); paint()
  addresses()   // the filter is the answer to the warning, so re-ask on every one
}

$('#filterbar').addEventListener('submit', e => { e.preventDefault(); filter($('#filter').value) })
$('#flowfilter').onclick = () => $('#filter').focus()

// -------------------------------------------------------------------- files ---

const human = n => n < 1024 ? n + ' B'
  : n < 1048576 ? (n / 1024).toFixed(0) + ' kB'
  : n < 1073741824 ? (n / 1048576).toFixed(1) + ' MB'
  : (n / 1073741824).toFixed(1) + ' GB'

async function files() {
  S.file = null
  $('#viewer').hidden = true
  $('#files').hidden = false
  for (const sel of ['#back', '#filterbar', '#mode']) $(sel).hidden = true
  $('#brand').hidden = false
  $('#name').hidden = true
  counter()
  sync()

  const captures = await api('captures').catch(err => { note(err.message); return [] })
  const table = $('#filelist')
  table.textContent = ''
  for (const c of captures) {
    const tr = table.insertRow()
    const name = tr.insertCell()
    name.className = 'n'
    const link = document.createElement('a')
    link.textContent = c.name
    link.onclick = () => openCapture(c.name)
    name.appendChild(link)
    tr.insertCell().outerHTML = '<td class=s>' + human(c.size) + '</td>'
    tr.insertCell().outerHTML = '<td class=a><a href="/api/file?f=' +
      encodeURIComponent(c.name) + '" download>download</a></td>'
  }
  $('#empty').hidden = captures.length > 0
}

// The row index of a frame number, for the link that carries one: with a filter the
// two are not the same number, and the only thing that knows the difference is the
// rows themselves - so the pages it could be in are fetched until it turns up.
// Frames come in capture order, so a page reaching past the wanted number settles
// it: the frame is not in the filtered set, and neither is a row for it.
async function locate(num) {
  for (let p = 0; ; p++) {
    const pending = S.pages.get(p)
    if (pending === undefined) await fetchPage(p)
    else if (typeof pending.then === 'function') await pending
    const page = S.pages.get(p)
    if (!Array.isArray(page)) return -1            // the fetch failed and said so
    const at = page.findIndex(row => row.n === num)
    if (at >= 0) return p * PAGE + at
    if (page.length < PAGE) return -1              // that page was the end of the set
    if (page[page.length - 1].n > num) return -1    // ...or already past the frame
  }
}

async function openCapture(file, want, num, as) {
  note('opening ' + file + ' …')
  let st
  try {
    st = await api('status', { f: file })
  } catch (err) {
    note(err.message); files(); return
  }
  S.file = file
  S.total = st.frames
  S.filter = want || ''
  columns(st)

  $('#files').hidden = true
  $('#viewer').hidden = false
  for (const sel of ['#back', '#filterbar']) $(sel).hidden = false
  $('#brand').hidden = true
  $('#name').hidden = false
  $('#name').textContent = st.filename.replace(/\.[^.]+$/, '')
  $('#filter').value = S.filter
  note('')
  // the viewer is on screen before the view is built, so the flow view can lay
  // its columns out against a width the window really has
  view(as === 'flow' && !$('#mode').hidden ? 'flow' : 'list')
  rewind()

  // a frame number is a row index of its own only while nothing is filtered
  if (num) {
    const at = S.filter ? await locate(num) : num - 1
    if (at >= 0) { reveal(at); select(at) }
  }
}

$('#back').onclick = () => {
  const file = S.file
  files()
  if (file) api('close', { f: file }, { method: 'POST' }).catch(() => {})
}

async function upload(chosen) {
  for (const file of chosen) {
    note('uploading ' + file.name + ' …')
    try {
      const res = await fetch('/api/file?f=' + encodeURIComponent(file.name), { method: 'POST', body: file })
      const body = await res.json()
      if (body.err) throw new Error(body.err)
    } catch (err) { note(file.name + ': ' + err.message); return }
  }
  note('')
  files()
}

$('#pick').onchange = e => upload(e.target.files)
document.addEventListener('dragover', e => { e.preventDefault(); document.body.classList.add('drop') })
document.addEventListener('dragleave', () => document.body.classList.remove('drop'))
document.addEventListener('drop', e => {
  e.preventDefault()
  document.body.classList.remove('drop')
  if (e.dataTransfer.files.length) upload(e.dataTransfer.files)
})

// -------------------------------------------------------------------- theme ---

// No setting means follow the system, which is what the CSS does on its own; the
// other two states stamp data-theme and are remembered.
const THEMES = ['system', 'light', 'dark']
const MARK = { system: '◉', light: '☀', dark: '☾' }

function theme(pick) {
  if (pick === 'system') { delete document.documentElement.dataset.theme; localStorage.removeItem('theme') }
  else { document.documentElement.dataset.theme = pick; localStorage.setItem('theme', pick) }
  const button = $('#theme')
  button.textContent = MARK[pick]
  button.title = 'Theme: ' + pick + ' (click to change)'
}

$('#theme').onclick = () => {
  const now = localStorage.getItem('theme') || 'system'
  theme(THEMES[(THEMES.indexOf(now) + 1) % THEMES.length])
}
theme(localStorage.getItem('theme') || 'system')

// -------------------------------------------------------------------- plumb ---

const note = text => { $('#msg').textContent = text }
// counts only - the word would be there in one form and not the other
function counter() {
  const el = $('#count')
  el.textContent = !S.file ? ''
    : S.filter ? S.count + (S.end ? '' : '+') + ' of ' + S.total
    : String(S.total)
  el.title = !S.file ? '' : S.filter ? 'matching frames of the capture' : 'frames'
}

// The URL is the whole of the app's state, so a view can be linked or reloaded.
function sync() {
  const p = new URLSearchParams()
  if (S.file) p.set('f', S.file)
  if (S.filter) p.set('q', S.filter)
  if (S.selIdx >= 0 && S.want) p.set('n', S.want)
  if (S.file && flowing()) p.set('v', 'flow')
  const query = p.toString()
  if ((query ? '#' + query : '') !== location.hash) {
    history.replaceState(null, '', query ? '#' + query : location.pathname)
  }
}

function restore() {
  const p = new URLSearchParams(location.hash.slice(1))
  if (p.get('f')) openCapture(p.get('f'), p.get('q') || '', +p.get('n') || 0, p.get('v'))
  else files()
}

list.addEventListener('scroll', paint, { passive: true })
new ResizeObserver(paint).observe(list)

addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT') {
    if (e.key === 'Escape') { e.target.blur(); filter('') }
    return
  }
  if (e.key === '/' || (e.key === 'f' && (e.ctrlKey || e.metaKey))) { e.preventDefault(); $('#filter').focus(); return }
  if ($('#viewer').hidden) return
  if (e.key === 'v' && !e.ctrlKey && !e.metaKey && !$('#mode').hidden) {
    view(flowing() ? 'list' : 'flow')
    return
  }
  const rows = Math.max(1, Math.floor(list.clientHeight / rowH()) - 1)
  const jump = { ArrowDown: 1, ArrowUp: -1, PageDown: rows, PageUp: -rows }[e.key]
  if (jump) { e.preventDefault(); move(jump) }
  else if (e.key === 'Home') { e.preventDefault(); reveal(0); select(0) }
  else if (e.key === 'End' && S.end) { e.preventDefault(); reveal(S.count - 1); select(S.count - 1) }
})

restore()
