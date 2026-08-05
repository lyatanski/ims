--
-- Relate SIP to Diameter by the subscriber a message is about.
--
-- This is the example Lua expansion for the image (see the Dockerfile): a
-- postdissector that hangs four generated fields off every SIP and Diameter
-- frame, so a single display filter reaches across both protocols:
--
--     ims.id == "001010000000001"     one subscriber, Gm/Mw through Cx and Gx
--     ims.ref == "Cx"                 every Cx message
--     ims.msg == "Cx/MAR"             one command, request leg only
--     ims.linked                      answers stitched to a request
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
--     Gx CCR     Subscription-Id-Data = 001010000000001
--     INVITE     To: <tel:+359000000001>
--
-- so every one of them is normalized down to the bare user part and that
-- becomes the key. `ims.id` is added once per distinct identity in the frame,
-- and a display filter matches if any occurrence matches - which is what makes
-- an INVITE come out under both the caller and the callee.
--
-- Diameter answers are the one case that needs state: a UAA or a CCA carries a
-- Session-Id and nothing else, so the identity is remembered per Session-Id
-- from the request and copied onto the answer, flagged as `ims.linked`. SIP
-- needs no such thing - From and To are in every message including responses.
--

set_plugin_info({
    version = '1.0',
    description = 'Relates SIP and Diameter by the subscriber a message is about',
})

local ims = Proto('ims', 'IMS correlation')

local F = {
    id     = ProtoField.string('ims.id', 'Subscriber identity'),
    ref    = ProtoField.string('ims.ref', 'Reference point'),
    msg    = ProtoField.string('ims.msg', 'Message'),
    linked = ProtoField.bool('ims.linked', 'Identity from session state'),
}
ims.fields = { F.id, F.ref, F.msg, F.linked }

-- Gm and Mw are the same protocol on the same port; only the endpoints tell
-- them apart, and only this deployment knows which those are. The default is
-- the UENET of the compose stack, so `-o ims.ue_subnet:10.0.0.0/8` (tshark and
-- sharkd) or the preference dialog covers anything else.
ims.prefs.ue_subnet = Pref.string('UE subnet', '10.10.0.0/16',
    'SIP with one endpoint in this prefix is Gm, everything else Mw')

-- Every identity-bearing field of both protocols. Order is irrelevant: all of
-- them are read and the results deduplicated.
local sip = {
    method = Field.new('sip.Method'),
    status = Field.new('sip.Status-Code'),
    cseq   = Field.new('sip.CSeq.method'),
    ids    = {
        Field.new('sip.auth.username'),   -- IMPI, the Cx User-Name verbatim
        Field.new('sip.pai.user'),        -- P-Asserted-Identity
        Field.new('sip.to.user'),
        Field.new('sip.from.user'),
        Field.new('sip.r-uri.user'),
    },
}

local dia = {
    cmd     = Field.new('diameter.cmd.code'),
    app     = Field.new('diameter.applicationId'),
    request = Field.new('diameter.flags.request'),
    session = Field.new('diameter.Session-Id'),
    ids     = {
        Field.new('diameter.User-Name'),
        Field.new('diameter.Public-Identity'),
        Field.new('diameter.Subscription-Id-Data'),
    },
}

local ip = { src = Field.new('ip.src'), dst = Field.new('ip.dst') }

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

local function identities(fields)
    local list, seen = {}, {}
    for _, field in ipairs(fields) do
        for _, fi in ipairs { field() } do
            push(list, seen, normalize(fi.value))
        end
    end
    return list
end

-- ------------------------------------------------------------------ state ---

-- Per-frame results, so a filter, a click in webshark and a second pass all
-- agree on what a frame said (see the dissector for what is and is not cached).
-- Session-Id -> identities is the request state the answers are stitched from.
local cache, by_session
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
    cache, by_session = {}, {}
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

-- --------------------------------------------------------------- per frame ---

local function truthy(v) return v == true or v == 1 end

local function diameter_frame()
    local codes = { dia.cmd() }
    if #codes == 0 then return nil end

    local apps, requests = { dia.app() }, { dia.request() }
    local entry = { ids = identities(dia.ids), msgs = {} }

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

    local sessions = {}
    for _, fi in ipairs { dia.session() } do
        sessions[#sessions + 1] = tostring(fi.value)
    end

    if #entry.ids > 0 then
        -- One message per frame is the norm and then the single Session-Id owns
        -- every identity in it. A TCP segment carrying several messages is only
        -- split up when the shapes line up - k-th Session-Id with k-th identity
        -- - because guessing wrong here would attribute one subscriber's answer
        -- to another.
        if #sessions == 1 then
            by_session[sessions[1]] = entry.ids
        elseif #sessions == #entry.ids then
            for i, session in ipairs(sessions) do
                by_session[session] = { entry.ids[i] }
            end
        end
    else
        local seen = {}
        for _, session in ipairs(sessions) do
            for _, id in ipairs(by_session[session] or {}) do
                push(entry.ids, seen, id)
                entry.linked = true
            end
        end
    end

    return entry
end

local function sip_frame()
    local methods, statuses = { sip.method() }, { sip.status() }
    if #methods == 0 and #statuses == 0 then return nil end

    local entry = { ids = identities(sip.ids), msgs = {} }
    entry.ref = (in_ue_subnet(ip.src) or in_ue_subnet(ip.dst)) and 'Gm' or 'Mw'

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

    return entry
end

function ims.dissector(tvb, pinfo, tree)
    -- Only hits are cached, never misses. sharkd dissects the whole file once
    -- when it opens it, and on that pass none of the fields read below are
    -- primed - every extractor returns nil - so a cached "nothing here" would
    -- stick for the rest of the session and every filter would come back empty.
    -- Re-running a frame that yielded nothing costs one nil extractor call.
    local entry = cache[pinfo.number]
    if not entry then
        entry = diameter_frame() or sip_frame()
        if not entry then return end
        cache[pinfo.number] = entry
    end

    local st = tree:add(ims, tvb(0, 0))
    st:set_text(string.format('IMS: %s%s', table.concat(entry.msgs, ' '),
        entry.ids[1] and (' ' .. table.concat(entry.ids, ' ')) or ''))
    st:set_generated()

    if entry.ref then st:add(F.ref, entry.ref) end
    for _, msg in ipairs(entry.msgs) do st:add(F.msg, msg) end
    for _, id in ipairs(entry.ids) do st:add(F.id, id) end
    if entry.linked then st:add(F.linked, true) end
end

register_postdissector(ims)
