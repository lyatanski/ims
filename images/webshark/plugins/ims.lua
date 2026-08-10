--
-- Relate SIP to Diameter by the subscriber a message is about.
--
-- This is the example Lua expansion for the image (see the Dockerfile): a
-- postdissector that hangs six generated fields off every SIP and Diameter
-- frame, so a single display filter reaches across both protocols:
--
--     ims.id == "001010000000001"     one subscriber, Gm/Mw through Cx and Gx
--     ims.impi == "001010000000001"   the same one, named by its IMPI
--     ims.impu == "359000000001"      ... and by any of its IMPUs
--     ims.ref == "Cx"                 every Cx message
--     ims.msg == "Cx/MAR"             one command, request leg only
--     ims.related                     identities this frame does not spell
--
-- Nothing on the wire correlates the two protocols. A Cx Session-Id is minted
-- by the CSCF and never appears in SIP; the SIP Call-ID never reaches the HSS.
-- The one thing both sides carry is the subscriber - spelled differently in
-- every header and AVP that holds it:
--
--     REGISTER   Authorization: username="001010000000001@ims.mnc01.mcc001..."
--     REGISTER   To: <sip:001010000000001@ims.mnc01.mcc001...>
--     Cx UAR     User-Name = 001010000000001@ims.mnc01.mcc001...
--     Cx UAR     Public-Identity = sip:001010000000001@ims.mnc01.mcc001...
--     Rx AAR     Subscription-Id-Data = sip:359000000001@ims.mnc01.mcc001...
--     INVITE     To: <tel:+359000000001>
--
-- so every one of them is normalized down to the bare user part and that
-- becomes the key. `ims.id` is added once per distinct identity in the frame,
-- and a display filter matches if any occurrence matches - which is what makes
-- an INVITE come out under both the caller and the callee.
--
-- ---------------------------------------------------------------------------
--
-- Those spellings are not all the same *kind* of name, and collapsing them to
-- one field loses the distinction that matters most in IMS. A subscriber has
-- one private identity, the IMPI, which authenticates and is never routed to,
-- and a set of public identities, the IMPUs, which route and never
-- authenticate. So they are two fields, `ims.impi` and `ims.impu`, and a key
-- can honestly be both: this deployment derives the IMPI from the IMSI and the
-- barred IMPU from the IMPI, so `001010000000001` is the user part of each.
--
--     Authorization username, Cx User-Name, <PrivateID>          -> ims.impi
--     To, From, P-Asserted/Preferred-Identity, Request-URI,
--     reg-event aor, Cx Public-Identity, <Identity>              -> ims.impu
--     Subscription-Id-Data          -> either, per Subscription-Id-Type
--
-- Splitting them is the easy half. Relating them is the point: the MSISDN and
-- the IMSI of one subscriber share no substring, so `ims.impu == "359000000001"`
-- and `ims.impi == "001010000000001"` pick out two disjoint sets of frames that
-- are the same person. The registration binds them, and the binding is on the
-- wire in exactly the messages that assert it:
--
--     REGISTER          Authorization username with To - one subscriber, and
--                       the only SIP method trusted to assert it (`sip_frame`
--                       has the reg event package and why it is not a fourth)
--     any Cx/Rx/Gx/Sh   3GPP defines one Diameter message as being about one
--                       subscriber, so all of its identities go together
--     Cx SAA            <PrivateID> with every <PublicIdentity><Identity> of
--                       the User-Data - the whole implicit registration set,
--                       and the only place the MSISDN IMPU and the IMPI ever
--                       appear in the same message
--
-- Those merge the identities into one class per subscriber; every other message
-- only reads it. The distinction is not pedantry - an INVITE holds two
-- subscribers, one in From and one in To, and merging on mere co-occurrence
-- would collapse a whole call flow into one class within a few frames.
--
-- Reading the class back is what puts an IMPI on a frame that only ever spells
-- the MSISDN - the Cx LIR for `tel:359000000001`, say - and those additions are
-- flagged `ims.related`, so a filter can always get back to what a frame
-- actually said. The class only grows, so a frame dissected before the SAA was
-- seen relates less than the same frame dissected after it; nothing is cached
-- across that, and the second look is the complete one.
--
-- Diameter answers need state of a different kind: a UAA or a CCA carries a
-- Session-Id and nothing else, so the identities are remembered per Session-Id
-- from the request and copied onto the answer, flagged as `ims.linked`. SIP
-- needs no such thing - From and To are in every message including responses.
--

set_plugin_info({
    version = '2.0',
    description = 'Relates SIP and Diameter by the subscriber a message is about',
})

local ims = Proto('ims', 'IMS correlation')

local F = {
    id      = ProtoField.string('ims.id', 'Subscriber identity'),
    impi    = ProtoField.string('ims.impi', 'Private identity (IMPI)'),
    impu    = ProtoField.string('ims.impu', 'Public identity (IMPU)'),
    ref     = ProtoField.string('ims.ref', 'Reference point'),
    msg     = ProtoField.string('ims.msg', 'Message'),
    linked  = ProtoField.bool('ims.linked', 'Identity from session state'),
    related = ProtoField.bool('ims.related', 'Identity from the IMPI/IMPU binding'),
}
ims.fields = { F.id, F.impi, F.impu, F.ref, F.msg, F.linked, F.related }

-- Gm and Mw are the same protocol on the same port; only the endpoints tell
-- them apart, and only this deployment knows which those are. The default is
-- the UENET of the compose stack, so `-o ims.ue_subnet:10.0.0.0/8` (tshark and
-- sharkd) or the preference dialog covers anything else.
ims.prefs.ue_subnet = Pref.string('UE subnet', '10.10.0.0/16',
    'SIP with one endpoint in this prefix is Gm, everything else Mw')

-- Every identity-bearing field of both protocols, under the role it carries.
-- Order within a role is irrelevant: all of them are read and the results
-- deduplicated.
local sip = {
    method = Field.new('sip.Method'),
    status = Field.new('sip.Status-Code'),
    cseq   = Field.new('sip.CSeq.method'),
    impi   = {
        Field.new('sip.auth.username'),   -- the Cx User-Name verbatim
    },
    impu   = {
        Field.new('sip.pai.user'),        -- P-Asserted-Identity
        Field.new('sip.ppi.user'),        -- P-Preferred-Identity
        Field.new('sip.to.user'),
        Field.new('sip.from.user'),
        Field.new('sip.r-uri.user'),
        -- the aor of a reg-event NOTIFY body, which Wireshark dissects out of
        -- application/reginfo+xml into a field of its own
        Field.new('reginfo.registration.aor'),
    },
}

local dia = {
    cmd      = Field.new('diameter.cmd.code'),
    app      = Field.new('diameter.applicationId'),
    request  = Field.new('diameter.flags.request'),
    session  = Field.new('diameter.Session-Id'),
    subtype  = Field.new('diameter.Subscription-Id-Type'),
    subdata  = Field.new('diameter.Subscription-Id-Data'),
    impi     = {
        Field.new('diameter.User-Name'),
    },
    impu     = {
        Field.new('diameter.Public-Identity'),
    },
}

-- The Cx User-Data (29.228 Annex C) rides in an AVP as a document, and
-- Wireshark hands it to the generic XML dissector, which knows no schema: every
-- element comes out as `xml.tag` and its text as `xml.cdata`, with nothing
-- linking the two. Which element a value came from is the whole question here -
-- `<ServerName>sip:smsc.epc...` is an iFC application server, not an identity -
-- so the two flat lists are put back together in `by_offset` below.
local xml = { tag = Field.new('xml.tag'), cdata = Field.new('xml.cdata') }

local USER_DATA = { privateid = 'impi', identity = 'impu' }

-- RFC 4006 Subscription-Id-Type. The IMSI is not literally an IMPI, but with no
-- ISIM the IMPI is derived from it (23.003 s13.3) and normalizing both leaves
-- the same user part, so it keys the same subscriber; an NAI is already in the
-- user@realm shape of an IMPI. Anything unpaired falls back to a public
-- identity, which is what Rx and Gx carry in an IMS deployment.
local SUBSCRIPTION = {
    [0] = 'impu',  -- END_USER_E164
    [1] = 'impi',  -- END_USER_IMSI
    [2] = 'impu',  -- END_USER_SIP_URI
    [3] = 'impi',  -- END_USER_NAI
    [4] = 'impi',  -- END_USER_PRIVATE
}

local ip = { src = Field.new('ip.src'), dst = Field.new('ip.dst') }

local ROLES = { 'impi', 'impu' }

-- Reference point per Diameter application id. Cx and Dx share 16777216 and
-- are indistinguishable without knowing whether the peer is an SLF, so both
-- come out as Cx.
local REF = {
    [0]        = 'base',   -- CER/DWR/DPR, no application
    [4]        = 'Ro',
    [16777216] = 'Cx',
    [16777217] = 'Sh',
    [16777236] = 'Rx',
    [16777238] = 'Gx',
    [16777251] = 'S6a',
}

-- Command codes as their two-letter stem; R or A is appended per the request
-- bit, which is how 3GPP names them (300 + request = UAR, 300 = UAA). Cx is
-- 29.229, Sh 29.329, S6a 29.272 - and 301 is Server-Assignment while 303 is
-- Multimedia-Auth, not the other way round, which `_ws.col.info` on a capture
-- will confirm.
local CMD = {
    [257] = 'CE', [258] = 'RA', [265] = 'AA', [271] = 'AC', [272] = 'CC',
    [274] = 'AS', [275] = 'ST', [280] = 'DW', [282] = 'DP', [300] = 'UA',
    [301] = 'SA', [302] = 'LI', [303] = 'MA', [304] = 'RT', [305] = 'PP',
    [306] = 'UD', [307] = 'PU', [308] = 'SN', [309] = 'PN', [316] = 'UL',
    [317] = 'CL', [318] = 'AI', [319] = 'ID', [320] = 'DS', [321] = 'PU',
    [322] = 'RS', [323] = 'NO',
}

-- ------------------------------------------------------------- identities ---

-- sip:001010000000001@ims.mnc01.mcc001.3gppnetwork.org;transport=udp
-- "001010000000001@ims.mnc01.mcc001.3gppnetwork.org"
-- tel:+359000000001
--                                                  -> 001010000000001 / 359000000001
local function normalize(raw)
    if raw == nil then return nil end
    local s = tostring(raw)
    s = s:gsub('"', ''):gsub('^%s+', ''):gsub('%s+$', '')
    s = s:gsub('^<', ''):gsub('>$', '')
    s = s:gsub('^%a[%w%+%-%.]*:', '')  -- sip: sips: tel: im: pres:
    s = s:gsub('[;%?].*$', '')         -- uri parameters and headers
    s = s:gsub('@.*$', '')             -- @domain
    s = s:gsub('^%+', '')              -- E.164 international prefix
    s = s:lower()
    if s == '' then return nil end
    return s
end

local function push(list, seen, value)
    if value and not seen[value] then
        seen[value] = true
        list[#list + 1] = value
    end
end

-- An identity set: the keys of one frame, or of one subscriber, held once per
-- role and once overall. `all` is what `ims.id` is drawn from, and keeping it
-- separate is what lets a key be an IMPI and an IMPU at the same time without
-- being listed twice as a subscriber identity.
local function new_set()
    return { all = {}, seen = {}, impi = {}, impu = {}, roles = {} }
end

local function add(set, key, role)
    if key == nil then return false end
    local tag = role .. ' ' .. key
    local fresh = not set.roles[tag]
    if fresh then
        set.roles[tag] = true
        set[role][#set[role] + 1] = key
    end
    push(set.all, set.seen, key)
    return fresh
end

local function empty(set)
    return #set.impi == 0 and #set.impu == 0
end

local function read(set, role, fields)
    for _, field in ipairs(fields) do
        for _, fi in ipairs { field() } do
            add(set, normalize(fi.value), role)
        end
    end
end

-- Two Wireshark fields that belong together - an element with its text, a
-- Subscription-Id-Type with its Data - arrive as two flat lists with nothing
-- linking them. Both were added in wire order out of the same tvb, so sorting
-- the pair by offset puts every value directly after the thing that names it,
-- and one walk down that list carries the name forward. Offsets are only ever
-- compared within one tvb here, which is why the SIP headers and an XML body
-- are never sorted against each other.
--
-- Ties are real and have to be broken all the way down: an element and the one
-- that closes it can be reported at the same offset, and `table.sort` raises
-- "invalid order function" rather than shrugging if the comparison says two
-- items each precede the other. Ranking names before values and falling back to
-- the order they were read in makes it a total order, so there is no such pair.
local function by_offset(names, values)
    local items = {}
    for _, fi in ipairs { names() } do
        items[#items + 1] = { off = fi.offset, seq = #items, rank = 0, name = tostring(fi.value) }
    end
    for _, fi in ipairs { values() } do
        items[#items + 1] = { off = fi.offset, seq = #items, rank = 1, value = fi.value }
    end
    table.sort(items, function(a, b)
        if a.off ~= b.off then return a.off < b.off end
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.seq < b.seq
    end)
    return items
end

-- <PrivateID>001010000000001@...</PrivateID> is the IMPI and every
-- <PublicIdentity><Identity> is one IMPU of the same subscriber. Any other
-- element of the User-Data, and any other XML in the frame, is skipped.
local function read_user_data(set)
    local current
    for _, item in ipairs(by_offset(xml.tag, xml.cdata)) do
        if item.name then
            -- open and close tags arrive alike, and a close ends the element it
            -- names rather than starting one, so it clears the role instead
            current = not item.name:match('^%s*</')
                and USER_DATA[item.name:lower():gsub('[^%a]', '')]
                or nil
        elseif current then
            add(set, normalize(item.value), current)
        end
    end
end

-- Subscription-Id is a grouped AVP, so the type and the data are separate
-- fields and only their order says which belongs to which.
local function read_subscription(set)
    local current
    for _, item in ipairs(by_offset(dia.subtype, dia.subdata)) do
        if item.name then
            current = SUBSCRIPTION[tonumber(item.name)]
        else
            add(set, normalize(item.value), current or 'impu')
            current = nil
        end
    end
end

-- ------------------------------------------------------------------ state ---

-- Per-frame results, so a filter, a click in webshark and a second pass all
-- agree on what a frame said (see the dissector for what is and is not cached).
-- Session-Id -> identity set is the request state the answers are stitched
-- from, and class_of is the IMPI/IMPU binding every frame is read through.
local cache, by_session, class_of
local ue_net, ue_bits

local function parse_subnet(pref)
    local addr, bits = tostring(pref):match('^%s*([%d%.]+)%s*/%s*(%d+)%s*$')
    if not addr then return nil, nil end
    local a, b, c, d = addr:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil, nil end
    return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d),
        tonumber(bits)
end

local function reset()
    cache, by_session, class_of = {}, {}, {}
    ue_net, ue_bits = parse_subnet(ims.prefs.ue_subnet)
end

-- Wireshark runs the init routine once per capture file, which is what stops
-- frame 7 of one file being answered with what frame 7 of the last one held.
-- Called here too, so no dissection can land on empty tables.
reset()
ims.init = reset
-- the cache holds Gm/Mw decisions taken under the old prefix, so it goes with
-- it; everything is recomputed on the redissection this callback triggers
ims.prefs_changed = reset

local function in_ue_subnet(field)
    if not ue_net then return false end
    local fi = field()
    if not fi then return false end
    local addr = select(1, parse_subnet(tostring(fi.value) .. '/32'))
    if not addr then return false end
    -- integer division by the host-part size compares the prefixes without
    -- needing bitwise operators, which Lua 5.1 does not have
    local block = 2 ^ (32 - ue_bits)
    return math.floor(addr / block) == math.floor(ue_net / block)
end

-- ------------------------------------------------------------ subscribers ---

-- One class per subscriber, holding every spelling of them seen so far under
-- the role it was seen in, and reachable from any one of those spellings.

-- Merge the identities of a message that is about a single subscriber. Classes
-- already holding any of them are absorbed into one, which is how the IMPI of
-- a REGISTER and the MSISDN IMPU of the SAA that follows it end up together.
local function unite(observed)
    local target
    for _, role in ipairs(ROLES) do
        for _, key in ipairs(observed[role]) do
            local cls = class_of[key]
            if cls and cls ~= target then
                if not target then
                    target = cls
                else
                    for _, r in ipairs(ROLES) do
                        for _, k in ipairs(cls[r]) do
                            add(target, k, r)
                            class_of[k] = target
                        end
                    end
                end
            end
        end
    end
    target = target or new_set()
    for _, role in ipairs(ROLES) do
        for _, key in ipairs(observed[role]) do
            add(target, key, role)
            class_of[key] = target
        end
    end
end

-- What the frame spells, plus everything else those subscribers are known by.
-- Returns the widened set and whether anything was in fact added, which is what
-- `ims.related` reports.
local function relate(observed)
    local out, related = new_set(), false
    local classes, seen = {}, {}
    for _, role in ipairs(ROLES) do
        for _, key in ipairs(observed[role]) do
            add(out, key, role)
            local cls = class_of[key]
            if cls and not seen[cls] then
                seen[cls] = true
                classes[#classes + 1] = cls
            end
        end
    end
    for _, cls in ipairs(classes) do
        for _, role in ipairs(ROLES) do
            for _, key in ipairs(cls[role]) do
                if add(out, key, role) then related = true end
            end
        end
    end
    return out, related
end

-- --------------------------------------------------------------- per frame ---

local function truthy(v) return v == true or v == 1 end

local function diameter_frame()
    local codes = { dia.cmd() }
    if #codes == 0 then return nil end

    local apps, requests = { dia.app() }, { dia.request() }
    local entry = { observed = new_set(), msgs = {} }

    for i, code in ipairs(codes) do
        local app = apps[i] or apps[1]
        local request = truthy(requests[i] and requests[i].value)
        local ref = REF[app and app.value] or ('app' .. tostring(app and app.value))
        local stem = CMD[code.value]
        entry.ref = entry.ref or ref
        entry.msgs[#entry.msgs + 1] = stem
            and string.format('%s/%s%s', ref, stem, request and 'R' or 'A')
            or string.format('%s/%d%s', ref, code.value, request and 'R' or 'A')
    end

    read(entry.observed, 'impi', dia.impi)
    read(entry.observed, 'impu', dia.impu)
    read_subscription(entry.observed)
    read_user_data(entry.observed)

    local sessions = {}
    for _, fi in ipairs { dia.session() } do
        sessions[#sessions + 1] = tostring(fi.value)
    end

    if not empty(entry.observed) then
        if #sessions == 1 then
            by_session[sessions[1]] = entry.observed
        end
        -- One message per frame is the norm and then everything in it is one
        -- subscriber's, which is what makes a Cx command a binding. A TCP
        -- segment carrying several messages says nothing of the sort - two
        -- subscribers' commands travel in one segment as readily as one's - so
        -- the identities are still read but nothing is bound or remembered.
        if #codes == 1 then unite(entry.observed) end
    else
        for _, session in ipairs(sessions) do
            local remembered = by_session[session]
            if remembered then
                for _, role in ipairs(ROLES) do
                    for _, key in ipairs(remembered[role]) do
                        add(entry.observed, key, role)
                        entry.linked = true
                    end
                end
            end
        end
    end

    return entry
end

local function sip_frame()
    local methods, statuses = { sip.method() }, { sip.status() }
    if #methods == 0 and #statuses == 0 then return nil end

    local entry = { observed = new_set(), msgs = {} }
    entry.ref = (in_ue_subnet(ip.src) or in_ue_subnet(ip.dst)) and 'Gm' or 'Mw'

    read(entry.observed, 'impi', sip.impi)
    read(entry.observed, 'impu', sip.impu)

    for _, fi in ipairs(methods) do
        entry.msgs[#entry.msgs + 1] = tostring(fi.value)
    end
    -- a response is named after the transaction it answers, so the filter for
    -- "the 401 to a REGISTER" does not also catch the 401 to an INVITE
    local cseq = { sip.cseq() }
    for i, fi in ipairs(statuses) do
        local method = cseq[i] or cseq[1]
        entry.msgs[#entry.msgs + 1] = method
            and string.format('%s %d', tostring(method.value), fi.value)
            or tostring(fi.value)
    end

    -- Registration is the one SIP transaction whose every identity is one
    -- subscriber's: To equals From, and the Authorization username beside them
    -- is that subscriber's IMPI. A dialog-forming request is the opposite - two
    -- subscribers in one message - so the method is what decides, on the CSeq
    -- rather than the request line, which covers the responses too.
    --
    -- `Event: reg` looks like it belongs here as well, since the aor of a
    -- reg-event NOTIFY is an IMPU of the user it is about. It does not: the test
    -- UA of this stack leaves Event and Accept on its INVITE from the SUBSCRIBE
    -- it built that message out of, and trusting the header merges the caller
    -- with the callee on the first call in the capture. A binding rule is only
    -- worth having if a malformed message cannot invoke it, and the aor of a
    -- genuine NOTIFY is bound by the SAA long before the NOTIFY is sent.
    for _, fi in ipairs(cseq) do
        if tostring(fi.value):upper() == 'REGISTER' then
            unite(entry.observed)
            break
        end
    end

    return entry
end

function ims.dissector(tvb, pinfo, tree)
    -- Only hits are cached, never misses. sharkd dissects the whole file once
    -- when it opens it, and on that pass none of the fields read below are
    -- primed - every extractor returns nil - so a cached "nothing here" would
    -- stick for the rest of the session and every filter would come back empty.
    -- Re-running a frame that yielded nothing costs one nil extractor call.
    --
    -- What is cached is what the frame itself said, which cannot change. The
    -- widening in `relate` is not cached and is redone every time, because the
    -- classes it reads keep growing: the SAA that ties an IMPI to an MSISDN
    -- comes hundreds of frames after the REGISTER, and caching the widened set
    -- would leave those early frames permanently short of it.
    local entry = cache[pinfo.number]
    if not entry then
        entry = diameter_frame() or sip_frame()
        if not entry then return end
        cache[pinfo.number] = entry
    end

    local ids, related = relate(entry.observed)

    local st = tree:add(ims, tvb(0, 0))
    st:set_text(string.format('IMS: %s%s', table.concat(entry.msgs, ' '),
        ids.all[1] and (' ' .. table.concat(ids.all, ' ')) or ''))
    st:set_generated()

    if entry.ref then st:add(F.ref, entry.ref) end
    for _, msg in ipairs(entry.msgs) do st:add(F.msg, msg) end
    for _, id in ipairs(ids.impi) do st:add(F.impi, id) end
    for _, id in ipairs(ids.impu) do st:add(F.impu, id) end
    for _, id in ipairs(ids.all) do st:add(F.id, id) end
    if entry.linked then st:add(F.linked, true) end
    if related then st:add(F.related, true) end
end

register_postdissector(ims)
