#!/bin/sh
# Container entrypoint: become kamailio, resolving the Gm address first.
#
# Why this exists: ims_ipsec_pcscf's `ipsec_listen_addr` is the address the
# protected ports bind to and the one the kernel SAs and xfrm policies are
# keyed on, and the module parses it with str2ipbuf()
# (ims_ipsec_pcscf_mod.c:226) -- a numeric IPv4 literal, never an interface
# name, and mod_init returns -1 for anything else. That is fine while the
# address is the pod's own, which the downward API can put in the environment
# before the container starts. It stops being fine the moment Gm moves onto a
# secondary interface: the address then comes from that network's IPAM at pod
# creation, so it exists neither at render time nor in any field Kubernetes
# will project. Something has to read it off the device, and it has to happen
# before kamailio parses its cfg.
#
# So: set GMDEV to the in-pod device name and IPSEC is derived from it. Leave
# GMDEV unset and whatever IPSEC the environment already carries is passed
# through untouched -- the single-interface case, which is the pod address
# under Kubernetes and a pinned one under compose.
#
# exec, so kamailio is still PID 1 and still receives signals directly: the
# kubelet's SIGTERM and the preStop hook in drain.sh both depend on it.

set -e

if [ -n "${GMDEV:-}" ]; then
	# Multus completes its CNI ADD before any container starts, so the
	# address is normally there on the first read. The wait is for the
	# IPAM plugin that is a shade slower than that -- cheaper than a
	# CrashLoopBackOff, whose backoff is measured in minutes.
	n=0
	while :; do
		IPSEC=$(ip -o -4 addr show dev "$GMDEV" 2>/dev/null |
			awk '{ sub("/.*", "", $4); print $4; exit }')
		[ -z "$IPSEC" ] || break
		n=$((n + 1))
		if [ "$n" -ge 30 ]; then
			echo "no IPv4 address on $GMDEV after ${n}s -- is the network attachment present?" >&2
			exit 1
		fi
		sleep 1
	done

	echo "Gm: $GMDEV $IPSEC"
	export IPSEC
fi

# -DD: do not daemonize. -E: log to stderr.
exec kamailio -DD -E "$@"
