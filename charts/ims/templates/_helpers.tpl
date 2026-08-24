{{/*
Expand the name of the chart.
*/}}
{{- define "ims.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ims.labels" -}}
{{ include "ims.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ims.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ims.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Wait for the state store -- and, for the I-CSCF, for what it has to read out of
it.

db_redis opens its connection at module init and does not retry, and ims_icscf
loads its S-CSCF list at the same point. The list is written by the S-CSCF's own
init container (see "ims.register"), and the two pods are created together, so
without a gate the I-CSCF wins the race about half the time and then answers
every REGISTER with "600 Busy everywhere - Empty list of S-CSCFs" while the
entry it wants sits in valkey. Only a restart clears it, which is exactly the
kind of failure that looks intermittent and isn't.

Call with (dict "root" $ "cscf" <role>).
*/}}
{{- define "ims.waitdb" -}}
{{- $valkey := printf "-h %s -p %v" (include "valkey.name" .root.Subcharts.rtpengine.Subcharts.valkey) .root.Values.rtpengine.valkey.ports.valkey }}
- name: wait-store
  image: {{ .root.Values.rtpengine.valkey.image.repository }}:{{ .root.Values.rtpengine.valkey.image.tag }}
  command:
  - sh
  - -ec
  - |
    until valkey-cli {{ $valkey }} ping | grep -q PONG; do
      echo "waiting for the state store"; sleep 2
    done
    {{- if eq "interrogating" .cscf }}
    until [ -n "$(valkey-cli {{ $valkey }} -n {{ .root.Values.db.interrogating }} HGET s_cscf:entry::1 s_cscf_uri)" ]; do
      echo "waiting for the S-CSCF to register itself"; sleep 2
    done
    {{- end }}
{{- end }}

{{/*
S-CSCF register
*/}}
{{- define "ims.register" -}}
- name: register
  image: {{ .Values.rtpengine.valkey.image.repository }}:{{ .Values.rtpengine.valkey.image.tag }}
  command:
  - valkey-cli
  - -c
  - -u
  - redis://{{ template "valkey.name" .Subcharts.rtpengine.Subcharts.valkey }}:{{ .Values.rtpengine.valkey.ports.valkey }}/{{ .Values.db.interrogating }}
  - HSET
  - s_cscf:entry::1
  - s_cscf_uri
  {{/*
    The S-CSCF's name in the home domain, not its Kubernetes Service name.

    This value is what the I-CSCF relays a REGISTER to, and it has to be a name
    the CSCFs can resolve -- they run dnsPolicy: None against this release's
    CoreDNS, which answers the 3gppnetwork.org zone and knows nothing of a bare
    `ims-scscf`, so that spelling came back "478 Unresolvable destination".
    It is also what serving.cfg computes for its own SRVURI, i.e. the
    Server-Name the S-CSCF puts in the SAR and the HSS stores -- so the two
    have to agree or an MT call is routed to a name that is not this pod.
  */}}
  - sip:scscf.{{ include "ims.realm.ims" . }}
{{- end }}

{{/*
IPsec init
*/}}
{{- define "ims.ipsec" -}}
- name: ipsec
  image: {{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
  command:
  - modprobe
  - -a
  args:
  - ah4
  - ah6
  - esp4
  - esp6
  - xfrm4_tunnel
  - xfrm6_tunnel
  - xfrm_user
  - ip_tunnel
  - tunnel4
  - tunnel6
  securityContext:
    capabilities:
      add:
      - SYS_MODULE
  volumeMounts:
  - name: kmod
    mountPath: /lib/modules
{{- end }}

{{/*
kernel module mount path
*/}}
{{- define "ims.kmod" -}}
- name: kmod
  hostPath:
    path: /lib/modules
{{- end }}


{{/*
The CoreDNS cluster IP, resolved rather than configured.

The CSCFs run `dnsPolicy: None` so that names in the home domain resolve at all,
and a nameserver in `dnsConfig` has to be a literal address known when the pod
spec is rendered -- before the Service that would own it exists. So one address
in the service CIDR has to be picked in advance. Rather than hardcode it and
make every caller pass a `--set`, take the `kubernetes` Service (always the
first address of the CIDR, in every cluster) and swap its last octet.

Order matters: an existing Service wins, so an upgrade never moves the address
out from under the pods still pointing at it. `lookup` returns nothing under
`helm template`, which is what the literal at the end is for.
*/}}
{{- define "ims.dnsIP" -}}
{{- $existing := lookup "v1" "Service" .Release.Namespace (printf "%s-dns" .Release.Name) -}}
{{- if and $existing $existing.spec $existing.spec.clusterIP -}}
{{- $existing.spec.clusterIP -}}
{{- else -}}
{{- $api := lookup "v1" "Service" "default" "kubernetes" -}}
{{- if and $api $api.spec $api.spec.clusterIP -}}
{{- regexReplaceAll "[0-9]+$" $api.spec.clusterIP "69" -}}
{{- else -}}
10.96.0.69
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Realms. `domain` interpolates mcc/mnc and the realms interpolate `domain`, so
both need tpl before anything can be appended.
*/}}
{{- define "ims.realm.ims" -}}
{{- tpl .Values.realm.ims . -}}
{{- end }}

{{- define "ims.realm.epc" -}}
{{- tpl .Values.realm.epc . -}}
{{- end }}
