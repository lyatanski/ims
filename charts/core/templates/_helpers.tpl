{{/*
Every template here takes (dict "root" $ "name" <component>) rather than reading
a chart-level context, because one chart now renders four daemons.

The `core.` prefix is not decoration. Helm's named-template namespace is global
across the whole dependency tree, so the four per-daemon charts this replaced
each defined `open5gs.labels` and the last one loaded won: every workload in the
release came out with the same selector, and every Service picked up all four
sets of pods. One definition, one prefix, no way for that to come back.
*/}}

{{- define "core.name" -}}
{{- printf "%s-%s" .root.Release.Name .name -}}
{{- end }}

{{- define "core.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{- define "core.labels" -}}
{{ include "core.selectorLabels" . }}
app.kubernetes.io/part-of: {{ .root.Chart.Name }}
{{- with .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/*
Realms. `domain` is itself a template (it interpolates mcc/mnc) and the realms
interpolate `domain`, so both need tpl. Called with the root context.
*/}}
{{- define "core.realm.epc" -}}
{{- tpl .Values.realm.epc . -}}
{{- end }}

{{- define "core.realm.ims" -}}
{{- tpl .Values.realm.ims . -}}
{{- end }}

{{/*
The dictionary extensions, in load order -- dict_dcca declares a dependency on
dict_nasreq and freeDiameter refuses to start if it is loaded first, so this is
an order and not a set. Shared by both Diameter config forms so the two cannot
drift; each renders it in its own syntax.

Call with the root context.
*/}}
{{- define "core.diameter.extensions" -}}
dict_rfc5777
dict_mip6i
dict_nasreq
dict_nas_mipv6
dict_dcca
dict_dcca_3gpp
{{- end }}

{{/*
Either form of the Diameter configuration, keyed off .Values.diameter.mode.
This emits the whole `freeDiameter:` key so that the two forms -- a path on the
same line, or a mapping under it -- are indented in one place rather than in
each conf/<node>.yaml.

Call with (dict "root" $ "name" <component> "c" <component values>).
*/}}
{{- define "core.diameter" -}}
{{- if eq .root.Values.diameter.mode "file" -}}
freeDiameter: /etc/freeDiameter/diameter.conf
{{- else if eq .root.Values.diameter.mode "inline" -}}
{{- include "core.diameter.inline" . }}
{{- else -}}
{{- fail (printf "diameter.mode must be \"file\" or \"inline\", got %q" .root.Values.diameter.mode) -}}
{{- end -}}
{{- end }}

{{/*
freeDiameter's own config file, handed to the daemon by path.

This is the form with no gaps: freeDiameter's own parser reads it, so anything
its grammar accepts is available here. See .Values.diameter.mode for what
choosing the inline form instead gives up.

Call with (dict "root" $ "name" <component> "c" <component values>).
*/}}
{{- define "core.diameter.conf" -}}
Identity = "{{ .name }}.{{ include "core.realm.epc" .root }}";
No_SCTP;
AppServThreads = {{ .root.Values.workers }};
SecPort = 0;
TcTimer = {{ .root.Values.tcTimer }};

{{ if .root.Values.debug }}LoadExtension = "/opt/lib/freeDiameter/dbg_msg_dumps.fdx" : "0x4444";
{{ end -}}
{{- range (include "core.diameter.extensions" .root | splitList "\n") }}
LoadExtension = "/opt/lib/freeDiameter/{{ . }}.fdx";
{{- end }}
{{ range .c.peers }}
{{- $peer := printf "%s.%s" .node (tpl (index $.root.Values.realm .realm) $.root) -}}
ConnectPeer = "{{ $peer }}" { No_TLS; {{ if .connect }}ConnectTo = "{{ $.root.Release.Name }}-{{ .node }}"; {{ end }}};
{{ end -}}
{{- end }}

{{/*
The same configuration as open5gs' inline `freeDiameter:` mapping.

Call with (dict "root" $ "name" <component> "c" <component values>).
*/}}
{{- define "core.diameter.inline" -}}
freeDiameter:
  identity: {{ .name }}.{{ include "core.realm.epc" .root }}
  realm: {{ include "core.realm.epc" .root }}
  listen_on: 0.0.0.0
  port: {{ .c.ports.diameter.port }}
  tc_timer: {{ .root.Values.tcTimer }}
  load_extension:
  {{- if .root.Values.debug }}
  {{/* The second LoadExtension argument is a conf file path everywhere else,
        but dbg_msg_dumps runs strtoul over it instead, so the mask survives
        the trip through diam_config_apply()'s fopen() probe unchanged. */ -}}
  - module: /opt/lib/freeDiameter/dbg_msg_dumps.fdx
    conf: "0x4444"
  {{- end }}
  {{- range (include "core.diameter.extensions" .root | splitList "\n") }}
  - module: /opt/lib/freeDiameter/{{ . }}.fdx
  {{- end }}
  connect:
  {{- range .c.peers }}
  {{- $peer := printf "%s.%s" .node (tpl (index $.root.Values.realm .realm) $.root) }}
  {{- /*
    Every address here is read with getaddrinfo(AI_NUMERICHOST), so a Service
    name is not resolved late -- it fails init and aborts the daemon. A peer
    this pod only ever accepts from is pointed at diameter.blackhole, which
    registers the identity without naming anything reachable.
  */}}
  {{- if .connect }}
  {{- if not .address }}
  {{- fail (printf "components.%s.peers[%s].address is required when diameter.mode is inline: open5gs reads it with getaddrinfo(AI_NUMERICHOST) and aborts on a Service name, so it has to be a literal IP" $.name .node) }}
  {{- end }}
  - identity: {{ $peer }}
    address: {{ .address }}
  {{- else }}
  - identity: {{ $peer }}
    address: {{ $.root.Values.diameter.blackhole }}
  {{- end }}
  {{- end }}
{{- end }}
