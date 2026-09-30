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
