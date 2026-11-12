#!/bin/sh
# Count the P-CSCF's IPsec SAs and policies every INTERVAL seconds, as CSV
# on stdout, until killed. Prometheus has no metric for them: they live in the
# kernel, in the P-CSCF's network namespace, so they are read from the host.
#
#     sample.sh [INTERVAL]          run from the compose project directory
set -u
interval=${1:-30}
pid=$(docker inspect -f '{{.State.Pid}}' "$(docker compose ps -q pcscf)")

echo time,sad,spd_in,spd_out
while :; do
	# "SAD count N" and "SPD IN N OUT N FWD N"
	sad=$(sudo nsenter -t "$pid" -n ip xfrm state count | awk '{print $3}')
	spd=$(sudo nsenter -t "$pid" -n ip xfrm policy count | awk '{print $3 "," $5}')
	echo "$(date +%s),$sad,$spd"
	sleep "$interval"
done
