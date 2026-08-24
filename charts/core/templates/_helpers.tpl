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
freeDiameter's own config file, rather than open5gs' inline `freeDiameter:` map.

The inline form silently drops what this deployment needs: open5gs v2.8.0 logs
`unknown key no_sctp` and `unknown key addr` and carries on, so TLS stayed
enabled and every CER from a CSCF came back as a CEA with no applications in it
-- which kamailio's cdp reports as "Total count of applications is 0" and then
fails `cdp_has_app()` forever. Nothing in either log says "TLS". The file form is
also what compose.yml uses, so the two deployments now configure Diameter the
same way.

Credentials are mandatory even though every peer is No_TLS: freeDiameter
validates its TLS setup during init regardless of whether any peer uses it.

Call with (dict "root" $ "name" <component> "c" <component values>).
*/}}
{{- define "core.diameter.conf" -}}
Identity = "{{ .name }}.{{ include "core.realm.epc" .root }}";
No_SCTP;
AppServThreads = {{ .root.Values.workers }};
{{/* Tc is the reconnect interval, 30s by default. The SMF and the PCRF both
      list each other, so the first connection is settled by the RFC 6733 5.6.4
      election -- and every round it loses costs a full Tc. Until it settles the
      SMF answers Create Session with "No Gx Diameter Peer", which reaches the
      UE as cause 100. */ -}}
TcTimer = {{ .root.Values.tcTimer }};
TLS_Cred = "/var/diameter/crt.pem", "/var/diameter/key.pem";
TLS_CA = "/var/diameter/crt.pem";

{{ if .root.Values.debug }}LoadExtension = "/opt/lib/freeDiameter/dbg_msg_dumps.fdx" : "0x4444";
{{ end -}}
LoadExtension = "/opt/lib/freeDiameter/dict_rfc5777.fdx";
LoadExtension = "/opt/lib/freeDiameter/dict_mip6i.fdx";
LoadExtension = "/opt/lib/freeDiameter/dict_nasreq.fdx";
LoadExtension = "/opt/lib/freeDiameter/dict_nas_mipv6.fdx";
LoadExtension = "/opt/lib/freeDiameter/dict_dcca.fdx";
LoadExtension = "/opt/lib/freeDiameter/dict_dcca_3gpp.fdx";
{{ range .c.peers }}
{{- $peer := printf "%s.%s" .node (tpl (index $.root.Values.realm .realm) $.root) -}}
{{- /*
  ConnectTo pins the transport address, because the peer's Diameter identity is
  a name in the home domain and only the IMS CoreDNS answers those -- which this
  pod does not use. Without it the dial-out never resolves; the accept direction
  works either way, which is why most of these are listed at all.
*/}}
ConnectPeer = "{{ $peer }}" { No_TLS; {{ if .connect }}ConnectTo = "{{ $.root.Release.Name }}-{{ .node }}"; {{ end }}};
{{ end -}}
{{- end }}
