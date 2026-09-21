#!/bin/sh
# S-CSCF drain, invoked from the pod's preStop hook.
#
# Why this exists: ims_usrloc_scscf has no persistence -- serving.cfg's db_mode
# is commented out and cannot be redis, because the module reads its tables with
# INNER JOIN SQL that db_redis cannot serve. So a replaced pod comes back with
# an empty usrloc while every UE still believes it is registered and the P-CSCF
# still holds a contact and a live IPsec SA. Nothing announces the loss, so the
# two views stay inconsistent until each UE's own refresh timer fires -- 360 s
# in the measured runs -- and in that window the P-CSCF forwards MT requests to
# a pod that has no binding for them.
#
# De-registering each IMPU before we exit clears the S-CSCF's own usrloc and
# emits one reg-event NOTIFY per subscriber. Measured on the compose stack
# against 10 subscribers, that NOTIFY carries
#
#     <registration aor="sip:..." state="terminated">
#         <contact state="terminated" event="expired" expires="0">
#             <uri>sip:10.10.0.18:5112</uri>
#         </contact>
#     </registration>
#
# the P-CSCF answers 200, unsubscribes from reg-event ("is in state terminated
# so unsubscribing", notify.c:398), and removes the contact -- taking its IPsec
# SAs with it. ulpcscf.status went 10 -> 0 records, ip xfrm 40 -> 0 SAs.
#
# Two things to know about that:
#
#  1. It depends on patches/0006-*.patch being in the image, and nothing here
#     detects its absence. Without it the <contact> children are missing
#     entirely and the P-CSCF keeps both the contact and the tunnel: measured
#     as a control in the same harness, still 10 records and 40 SAs 75 s after
#     the drain. ims_registrar_pcscf only deletes a contact it can find from a
#     <contact> child (notify.c:193-223).
#
#     Upstream, reg_rpc_dereg_impu sets contact->state = CONTACT_DELETED two
#     statements after queueing the notification, while the body is rendered
#     later by the forked notification worker (generate_reginfo_full), and
#     process_xml_for_contact() returns early for CONTACT_DELETED
#     (registrar_notify.c:1930). The worker cannot win that: the RPC process
#     holds the contact slot lock and the udomain lock the renderer needs
#     across both assignments. A real de-REGISTER through save.c loses the
#     identical race and still carries contacts, because it copies the Contact
#     URIs into the notification as explit_dereg_contact and
#     generate_reginfo_full renders those from its own copy without consulting
#     usrloc. That, not the Cx round trip, is why a de-REGISTER clears the
#     P-CSCF -- and 0006 gives dereg_impu the same treatment. Reasoning and
#     numbers in DRAIN-STATUS.md 3.1-3.2 and 5.1.
#
#  2. No Cx SAR is sent (reg_rpc.c only walks linked_contacts and notifies),
#     so the HSS keeps this pod's Server-Name. That is correct for a rolling
#     update, where the ordinal returns under the same name, but it means this
#     script is not sufficient for a scale-in, which must also clear the
#     assignment and drop the pod's s_cscf registry row.
#
# `linger` below is load-bearing either way: Kubernetes withdraws the endpoint
# and sends SIGTERM concurrently, so without it in-flight transactions die
# whatever the de-registration achieved.
#
# Knobs, all optional -- the chart sets them from values.yaml:
#   DRAIN_RPC         JSON-RPC endpoint            (default http://127.0.0.1:9091/RPC)
#   DRAIN_MON         monitor endpoint             (default http://127.0.0.1:9090)
#   DRAIN_UNPUBLISH   1 to drop the s_cscf row first        (default 0)
#   DRAIN_DEREGISTER  1 to de-register, 0 to only linger    (default 1)
#   DRAIN_RATE        IMPUs per second, 0 = unpaced         (default 20)
#   DRAIN_BUDGET      hard cap on the de-registration phase (default 60)
#   DRAIN_LINGER      seconds to keep serving before exit   (default 35)

set -u

RPC=${DRAIN_RPC:-http://127.0.0.1:9091/RPC}
MON=${DRAIN_MON:-http://127.0.0.1:9090}
UNPUB=${DRAIN_UNPUBLISH:-0}
DEREG=${DRAIN_DEREGISTER:-1}
RATE=${DRAIN_RATE:-20}
BUDGET=${DRAIN_BUDGET:-60}
LINGER=${DRAIN_LINGER:-35}

log() { echo "drain: $*"; }

WORK=$(mktemp -d 2>/dev/null) || WORK=/tmp/drain.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

# One JSON-RPC call. Params are passed positionally as strings, which is all
# the two commands we use take; jsonrpcs ignores param names anyway.
rpc() {
	_m=$1
	shift
	_p=
	for _a in "$@"; do
		_p="${_p:+$_p,}\"$_a\""
	done
	wget -q -O - -T 10 \
		--header 'Content-Type: application/json' \
		--post-data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$_m\",\"params\":[$_p]}" \
		"$RPC"
}

# The set of registered IMPUs.
#
# There is no RPC that returns it: ulscscf.status reports only per-domain
# aggregates (Records, Max-Slots) and ulscscf.showimpu needs the IMPU you are
# looking for. ulscscf.snapshot is the only primitive that walks every udomain
# slot, and it writes a print_impurecord() dump to a file we name -- with
# fopen(path, "a"), so the file must not already exist and the path must be
# writable, or the module dereferences a NULL FILE* and takes kamailio with it.
#
# Each record prints, in this order:
#	public_identity    : 'sip:...'
#	state:  'registered (1)'
#	barring: '0'
#
# Match the state's numeric code, not its name: the strings are "registered",
# "unregistered" and "not registered", and the last one *contains* the first,
# so a substring test would drain deregistered records too. Barred IMPUs are
# skipped -- they share the subscription's contacts with the non-barred one, so
# they would only re-delete contacts already marked deleted.
impus() {
	rm -f "$WORK/snap"
	rpc ulscscf.snapshot "$WORK/snap" >/dev/null 2>&1 || return 1
	[ -s "$WORK/snap" ] || return 1
	sed -n \
		-e "s/^[[:space:]]*public_identity[[:space:]]*:[[:space:]]*'\(.*\)'.*/IMPU \1/p" \
		-e "s/^[[:space:]]*state:[[:space:]]*'.*(\(-\{0,1\}[0-9]\{1,\}\))'.*/STATE \1/p" \
		-e "s/^[[:space:]]*barring:[[:space:]]*'\([0-9]\{1,\}\)'.*/BARRING \1/p" \
		"$WORK/snap" |
		awk '
			$1 == "IMPU"    { impu = $2; next }
			$1 == "STATE"   { reg = ($2 == "1"); next }
			$1 == "BARRING" {
				if (impu != "" && reg && $2 == "0") print impu
				impu = ""; reg = 0; next
			}'
}

# Drop this S-CSCF from the I-CSCF's candidate table before anything else, so
# the window in which a fresh REGISTER can still be handed to a pod that is
# going away closes before we spend the de-registration budget below.
#
# serving.cfg publishes the row from event_route[core:worker-one-init] and
# monitor.cfg answers /unpublish with the matching DEL; both are compiled only
# when REGSRV is set, so this is a no-op the chart leaves off for the other two
# roles. Failure is logged and ignored -- it costs a stale row, and a preStop
# hook that exits non-zero just gets SIGTERM sooner.
#
# Note what this does *not* do: a running I-CSCF loaded the table in mod_init
# and closed the connection, so its snapshot is immutable. The DEL only takes
# effect for an I-CSCF that starts afterwards -- which is why it matters most
# for a scale-in, where the row would otherwise outlive its pod and become a
# black hole for the next I-CSCF to start.
if [ "$UNPUB" = "1" ]; then
	if wget -q -O - -T 10 "$MON/unpublish" >/dev/null 2>&1; then
		log "unpublished from the S-CSCF candidate table"
	else
		log "could not unpublish; the s_cscf row is left behind"
	fi
fi

if [ "$DEREG" = "1" ]; then
	if impus >"$WORK/impus"; then
		total=$(wc -l <"$WORK/impus")
		log "de-registering $total IMPU(s) at ${RATE}/s, budget ${BUDGET}s"
		# The work is proportional to the registered subscriber count, which
		# the chart cannot know at render time. Bounding the phase here is what
		# lets terminationGracePeriodSeconds be derived from these knobs
		# instead of guessed -- overrunning it would have the kubelet SIGKILL
		# us mid-drain, losing the linger below as well.
		deadline=$(($(date +%s) + BUDGET))
		n=0
		while read -r impu; do
			[ -n "$impu" ] || continue
			if [ "$(date +%s)" -ge "$deadline" ]; then
				log "budget exhausted after $n of $total; the remainder fall back to their refresh timers"
				break
			fi
			rpc regscscf.dereg_impu "$impu" >/dev/null 2>&1 ||
				log "dereg failed for $impu"
			n=$((n + 1))
			# Pace the NOTIFY burst -- each dereg emits one NOTIFY per
			# reg-event subscriber through tm. Whole-second sleeps every
			# RATE calls, because busybox sleep is the only timer here.
			if [ "$RATE" -gt 0 ] && [ $((n % RATE)) -eq 0 ]; then
				sleep 1
			fi
		done <"$WORK/impus"
		log "de-registered $n IMPU(s)"
	else
		# Not fatal: an empty or unreachable usrloc still has to linger, and a
		# preStop hook that exits non-zero just gets SIGTERM sooner.
		log "could not enumerate usrloc; skipping de-registration"
	fi
fi

# Keep serving while the endpoint is withdrawn -- Kubernetes removes it and
# sends SIGTERM concurrently, so this is what covers in-flight transactions and
# the NOTIFYs issued above. Must exceed SIP timer B (32 s at default T1), and
# terminationGracePeriodSeconds must exceed the whole script.
log "lingering ${LINGER}s for in-flight transactions"
sleep "$LINGER"
log "done"
