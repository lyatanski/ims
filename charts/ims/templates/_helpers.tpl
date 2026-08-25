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
Wait redis! db_redis opens its connection at module init and does not retry

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

{{/*
The route to the UE pool, capped to the MTU the GTP-U tunnel leaves.
*/}}
{{- define "ims.ueroute" -}}
- name: ueroute
  image: {{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  securityContext:
    capabilities:
      add:
      - NET_ADMIN
  command:
  - sh
  - -c
  - |
    pool={{ .Values.global.ue.subnet }}
    mtu={{ .Values.global.ue.mtu }}

    while :; do
      # "default via <gw> dev <dev>" -> "<gw> <dev>"
      set -- $(ip route | awk '$1 == "default" { print $3, $5; exit }')
      if [ -n "$1" ]; then
        ip route replace "$pool" via "$1" dev "$2" mtu "$mtu"
      fi
      sleep {{ .Values.reconcile }}
    done
{{- end }}
