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

{{- define "core.realm.epc" -}}
{{- tpl .Values.realm.epc . -}}
{{- end }}

{{- define "core.realm.ims" -}}
{{- tpl .Values.realm.ims . -}}
{{- end }}

{{- define "core.diameter.extensions" -}}
dict_rfc5777
dict_mip6i
dict_nasreq
dict_nas_mipv6
dict_dcca
dict_dcca_3gpp
{{- end }}

{{- define "core.diameter" -}}
{{- if eq .root.Values.diameter.mode "file" -}}
freeDiameter: /etc/freeDiameter/diameter.conf
{{- else if eq .root.Values.diameter.mode "inline" -}}
{{- include "core.diameter.inline" . }}
{{- else -}}
{{- fail (printf "diameter.mode must be \"file\" or \"inline\", got %q" .root.Values.diameter.mode) -}}
{{- end -}}
{{- end }}

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

{{- define "core.diameter.inline" -}}
freeDiameter:
  identity: {{ .name }}.{{ include "core.realm.epc" .root }}
  realm: {{ include "core.realm.epc" .root }}
  listen_on: 0.0.0.0
  port: {{ .c.ports.diameter.port }}
  tc_timer: {{ .root.Values.tcTimer }}
  load_extension:
  {{- if .root.Values.debug }}
  - module: /opt/lib/freeDiameter/dbg_msg_dumps.fdx
    conf: "0x4444"
  {{- end }}
  {{- range (include "core.diameter.extensions" .root | splitList "\n") }}
  - module: /opt/lib/freeDiameter/{{ . }}.fdx
  {{- end }}
  connect:
  {{- range .c.peers }}
  {{- $peer := printf "%s.%s" .node (tpl (index $.root.Values.realm .realm) $.root) }}
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

{{/*
The UE pool's prefix length, for turning session.gateway into an address.
*/}}
{{- define "core.session.prefixlen" -}}
{{- .Values.session.subnet | splitList "/" | last -}}
{{- end }}

{{/*
The UPF's TUN device, addressed and up.

Call with (dict "root" $ "name" <component>).
*/}}
{{- define "core.tun" -}}
- name: tun
  image: {{ .root.Values.image.repository }}:{{ .root.Values.image.tag | default .root.Chart.AppVersion }}
  imagePullPolicy: {{ .root.Values.image.pullPolicy }}
  securityContext:
    capabilities:
      add:
      - NET_ADMIN
  command:
  - sh
  - -c
  - |
    # Both calls are idempotent -- `addr add` fails with EEXIST once the
    # address is set, `link set up` is a no-op on a device already up -- so
    # there is nothing to test for first and nothing to undo.
    while :; do
      ip addr add {{ .root.Values.session.gateway }}/{{ include "core.session.prefixlen" .root }} dev {{ .root.Values.session.dev }} 2>/dev/null
      ip link set {{ .root.Values.session.dev }} up 2>/dev/null
      sleep {{ .root.Values.reconcile }}
    done
{{- end }}
