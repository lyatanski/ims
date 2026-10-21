{{/*
Expand the name of the chart.
*/}}
{{- define "rtpengine.name" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rtpengine.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rtpengine.labels" -}}
helm.sh/chart: {{ include "rtpengine.chart" . }}
{{ include "rtpengine.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rtpengine.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rtpengine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
The `k8s.v1.cni.cncf.io/networks` annotation: one entry per interface that is
attached to a secondary network, in the order the interfaces are listed.

The JSON list form rather than the bare "name" string, because only the list
form carries `interface`, and an interface's `address` names the device that
the attachment has to create. Left to Multus it would be `net1`, `net2`, ... in
attachment order -- stable only as long as nothing else is attached to the same
pod, and rtpengine would then be binding a device nobody named.

Empty output when no interface is attached, so the caller can use it as the
condition for the annotation itself.

Call with the root context.
*/}}
{{- define "rtpengine.networks" -}}
{{- $root := . -}}
{{- $attach := list -}}
{{- range $if := .Values.media.interfaces -}}
{{- if and $if.network $if.network.enabled -}}
{{- $name := include "rtpengine.network.name" (dict "root" $root "name" $if.network.name) -}}
{{- $attach = append $attach (dict "name" $name "interface" $if.address) -}}
{{- end -}}
{{- end -}}
{{- with $attach }}{{- toJson . }}{{- end -}}
{{- end }}

{{/*
A NetworkAttachmentDefinition's name, prefixed the way every other object this
chart owns is.

A NAD is a namespaced object and `network.name` is the same string in every
release, so without the prefix two releases in one namespace write the same
object: the second install fails on an ownership conflict, and an upgrade of
either one silently re-points the other release's media onto a different
subnet.

Call with (dict "root" $ "name" <network.name>).
*/}}
{{- define "rtpengine.network.name" -}}
{{- printf "%s-%s" (include "rtpengine.name" .root) .name -}}
{{- end }}

{{/*
A NetworkAttachmentDefinition's `spec.config`: the CNI config verbatim, with
`name` defaulted to the attachment's own so the two cannot drift. `merge` lets
the config win, so an explicit `name` in it is still honoured, and deepCopy
keeps it from writing back into .Values.

The default is the prefixed name for the same reason the object carries it, and
this one is the easier of the two to miss: the CNI network name is what
host-local keys its allocations on -- /var/lib/cni/networks/<name> -- so two
releases sharing it hand out addresses from one pool into two subnets.

Call with (dict "root" $ "network" <interface's network dict>).
*/}}
{{- define "rtpengine.network.config" -}}
{{- $name := include "rtpengine.network.name" (dict "root" .root "name" .network.name) -}}
{{- toJson (merge (deepCopy .network.config) (dict "name" $name)) -}}
{{- end }}

{{/*
Check `media.interfaces` and `templates` against each other and against what
rtpengine will accept, and fail the render rather than let a mistake become a
call that connects and has no audio.

What it catches: an interface with neither an address nor an alias, a duplicate
name (rtpengine requires the config section names to be unique), an alias
pointing at an interface that is not in the list, an alias carrying a network
of its own, two interfaces attaching the same network -- which the chart would
render twice, because it creates it -- and, the one worth having,
a template whose `direction=` names an interface nobody defined, which
rtpengine itself accepts and silently answers on its default interface.

Call with the root context. Renders nothing.
*/}}
{{- define "rtpengine.validate" -}}
{{- $ifaces := .Values.media.interfaces -}}
{{- if not $ifaces }}{{- fail "rtpengine: media.interfaces is empty; rtpengine cannot start without one" }}{{- end -}}
{{- $names := list -}}
{{- $nets := list -}}
{{- range $if := $ifaces -}}
{{- if not $if.name }}{{- fail (printf "rtpengine: interface %v has no name" $if) }}{{- end -}}
{{- if has $if.name $names }}{{- fail (printf "rtpengine: interface %q is listed twice" $if.name) }}{{- end -}}
{{- if and (not $if.address) (not $if.alias) }}
{{- fail (printf "rtpengine: interface %q needs an address or an alias" $if.name) }}
{{- end -}}
{{- if and $if.address $if.alias }}
{{- fail (printf "rtpengine: interface %q has both an address and an alias" $if.name) }}
{{- end -}}
{{- if and $if.alias (not (has $if.alias $names)) }}
{{- fail (printf "rtpengine: interface %q is an alias of %q, which is not an interface in front of it" $if.name $if.alias) }}
{{- end -}}
{{- if and $if.network $if.network.enabled -}}
{{- if $if.alias }}
{{- fail (printf "rtpengine: interface %q is an alias and cannot carry a network; put it on %q instead" $if.name $if.alias) }}
{{- end -}}
{{- if not $if.network.name }}{{- fail (printf "rtpengine: interface %q has a network with no name" $if.name) }}{{- end -}}
{{- /* The chart renders the NAD, so a shared name is a duplicate object */ -}}
{{- if has $if.network.name $nets }}
{{- fail (printf "rtpengine: interface %q attaches network %q, which another interface already attaches; the chart creates it, so the name has to be unique" $if.name $if.network.name) }}
{{- end -}}
{{- $nets = append $nets $if.network.name -}}
{{- end -}}
{{- if or $if.vips $if.vips6 -}}
{{- if $if.alias }}
{{- fail (printf "rtpengine: interface %q is an alias and cannot carry vips; put them on %q instead" $if.name $if.alias) }}
{{- end -}}
{{- /* the rest of the group would be handed out to a replica's calls too */ -}}
{{- if contains ":" $if.name }}
{{- fail (printf "rtpengine: interface %q is in a round-robin group and cannot carry vips" $if.name) }}
{{- end -}}
{{- if $if.advertised }}
{{- fail (printf "rtpengine: interface %q has both vips and an advertised address" $if.name) }}
{{- end -}}
{{- if or (eq "any" $if.address) (regexMatch "^[0-9.]+$|:" $if.address) }}
{{- fail (printf "rtpengine: interface %q has vips, so its address has to name the device they go on, not %q" $if.name $if.address) }}
{{- end -}}
{{- range $l := list $if.vips $if.vips6 -}}
{{- if and $l (ne (len $l) (int $.Values.replicaCount)) }}
{{- fail (printf "rtpengine: interface %q needs one vip per replica (%d), has %v" $if.name (int $.Values.replicaCount) $l) }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $names = append $names $if.name -}}
{{- end -}}
{{- /* `direction=` also takes the base of a `base:suffix` round-robin group */ -}}
{{- $known := $names -}}
{{- range $n := $names }}{{- $known = append $known (splitList ":" $n | first) }}{{- end -}}
{{- range $name, $flags := .Values.templates -}}
{{- range $flag := regexFindAll "direction=[^[:space:]]+" $flags -1 -}}
{{- $want := trimPrefix "direction=" $flag -}}
{{- if not (has $want $known) }}
{{- fail (printf "rtpengine: template %q sends %q to interface %q, which media.interfaces does not define" $name $flag $want) }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The interfaces split into one logical interface per owner: every one with
`vips` or `vips6`, and every alias of one. A JSON list of names; read it back
with fromJsonArray.

Call with the root context.
*/}}
{{- define "rtpengine.vip.names" -}}
{{- $per := list -}}
{{- range $if := .Values.media.interfaces -}}
{{- if or $if.vips $if.vips6 (and $if.alias (has $if.alias $per)) -}}
{{- $per = append $per $if.name -}}
{{- end -}}
{{- end -}}
{{- toJson $per -}}
{{- end }}

{{/*
The first interface with `vips` or `vips6`, the one the ng control socket is
addressed on: as JSON, `{}` when there is none.

Call with the root context.
*/}}
{{- define "rtpengine.vip.control" -}}
{{- $ctl := dict -}}
{{- range $if := .Values.media.interfaces -}}
{{- if and (not $ctl) (or $if.vips $if.vips6) }}{{ $ctl = $if }}{{ end -}}
{{- end -}}
{{- toJson $ctl -}}
{{- end }}

{{/*
kamailio's `rtpengine_sock`: one node per replica on its control address when
the interfaces carry `vips` (IPv4 preferred), the ClusterIP Service otherwise.
A call stays on the node it was hashed to for its whole life, so the node has
to be an address that moves with the call rather than a pod.

Call with this chart's context -- from a parent, `.Subcharts.rtpengine`.
*/}}
{{- define "rtpengine.ng" -}}
{{- $ctl := include "rtpengine.vip.control" . | fromJson -}}
{{- $port := .Values.service.port -}}
{{- if $ctl -}}
{{- $nodes := list -}}
{{- range $a := $ctl.vips }}{{ $nodes = append $nodes (printf "udp:%s:%v" $a $port) }}{{ end -}}
{{- if not $nodes -}}
{{- range $a := $ctl.vips6 }}{{ $nodes = append $nodes (printf "udp6:%s:%v" $a $port) }}{{ end -}}
{{- end -}}
{{- join " " $nodes -}}
{{- else -}}
udp:{{ include "rtpengine.name" . }}:{{ $port }}
{{- end -}}
{{- end }}

{{/*
The `k8s.v1.cni.cncf.io/networks` entry a client of the ng socket needs to
reach the control addresses -- the control interface's attachment, on a device
of the same name -- or nothing when the control socket is behind the Service.

Call with this chart's context.
*/}}
{{- define "rtpengine.ng.network" -}}
{{- $ctl := include "rtpengine.vip.control" . | fromJson -}}
{{- if and $ctl $ctl.network $ctl.network.enabled -}}
{{- toJson (dict "name" (include "rtpengine.network.name" (dict "root" . "name" $ctl.network.name)) "interface" $ctl.address) -}}
{{- end -}}
{{- end }}

{{/*
The init script that puts a replica's own `vips` on their devices, before
rtpengine binds them. ip_nonlocal_bind first, because the replica also binds
the addresses of the one it is standby for, which are not on this pod. DAD off
on the device, or the IPv6 address is tentative -- unusable -- for its first
second. The unsolicited ARP replaces whatever MAC the network still has for
the address, which after a reschedule is the previous pod's.

Call with the root context. Empty when no interface has `vips`.
*/}}
{{- define "rtpengine.vip.script" -}}
{{- $root := . -}}
{{- $ifs := list -}}
{{- range $if := .Values.media.interfaces }}{{ if or $if.vips $if.vips6 }}{{ $ifs = append $ifs $if }}{{ end }}{{ end -}}
{{- if $ifs -}}
set -e
sysctl -w net.ipv4.ip_nonlocal_bind=1 net.ipv6.ip_nonlocal_bind=1
case "$HOSTNAME" in
{{- range $i := until (int .Values.replicaCount) }}
{{ include "rtpengine.name" $root }}-{{ $i }})
{{- range $if := $ifs }}
{{- with $if.vips }}
	ip addr add {{ index . $i }}/32 dev {{ $if.address }}
	arping -U -c 1 -I {{ $if.address }} {{ index . $i }} || :
{{- end }}
{{- with $if.vips6 }}
	sysctl -w net.ipv6.conf.{{ $if.address }}.accept_dad=0
	ip -6 addr add {{ index . $i }}/128 dev {{ $if.address }}
{{- end }}
{{- end }}
	;;
{{- end }}
esac
{{- end -}}
{{- end }}
