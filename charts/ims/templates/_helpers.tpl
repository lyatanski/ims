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
The Diameter identity, `<instance>.<ims realm>`: the pod name, or `instance`
when given. A P-CSCF StatefulSet per Gm address passes its own name, so
`<release>-pcscf-<index>` stays the identity core's ConnectPeer list
enumerates rather than becoming `<release>-pcscf-<index>-0`.

Call with (dict "root" $ "instance" <name or "">).
*/}}
{{- define "ims.identity" -}}
{{- $root := .root -}}
{{- with $root }}
- name: identity
  image: {{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- with .Values.sidecar.resources }}
  resources: {{- toYaml . | nindent 4 }}
  {{- end }}
  env:
  - name: INSTANCE
    {{- with $.instance }}
    value: {{ . | quote }}
    {{- else }}
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
    {{- end }}
  command:
  - sh
  - -ec
  - |
    sed "s/@IDENTITY@/$INSTANCE/" /tmpl/diameter.xml > /run/cscf/diameter.xml
    if grep -q "@IDENTITY@" /run/cscf/diameter.xml; then
      echo "identity substitution failed"; exit 1
    fi
    cat /run/cscf/diameter.xml
  volumeMounts:
  - name: diameter
    mountPath: /tmpl
  - name: identity
    mountPath: /run/cscf
{{- end }}
{{- end }}

{{/*
Wait redis! db_redis opens its connection at module init and does not retry

Call with (dict "root" $ "cscf" <role>).
*/}}
{{- define "ims.waitdb" -}}
{{- $valkey := printf "-h %s -p %v" (include "valkey.name" .root.Subcharts.rtpengine.Subcharts.valkey) .root.Values.rtpengine.valkey.ports.valkey }}
- name: wait-store
  image: {{ .root.Values.rtpengine.valkey.image.repository }}:{{ .root.Values.rtpengine.valkey.image.tag }}
  {{- with .root.Values.sidecar.resources }}
  resources: {{- toYaml . | nindent 4 }}
  {{- end }}
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

{{- define "ims.regsrv" -}}
addr={{ template "valkey.name" .Subcharts.rtpengine.Subcharts.valkey }};port={{ .Values.rtpengine.valkey.ports.valkey }};db={{ .Values.db.interrogating }}
{{- end }}

{{/*
IPsec init
*/}}
{{- define "ims.ipsec" -}}
- name: ipsec
  image: {{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- with .Values.sidecar.resources }}
  resources: {{- toYaml . | nindent 4 }}
  {{- end }}
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
A NetworkAttachmentDefinition's `spec.config`: the CNI config verbatim, with
`name` defaulted to the attachment's own so the two cannot drift. `merge` lets
the config win, so an explicit `name` in it is still honoured, and deepCopy
keeps it from writing back into .Values.

The default is the release-prefixed name for the same reason the object carries
it, and this one is the easier of the two to miss: the CNI network name is what
host-local keys its allocations on -- /var/lib/cni/networks/<name> -- so two
releases sharing it hand out addresses from one pool into two subnets.

Call with the root context.
*/}}
{{- define "ims.network.config" -}}
{{- toJson (merge (deepCopy .Values.gm.config) (dict "name" (printf "%s-gm" .Release.Name))) -}}
{{- end }}

{{/*
The route to the UE pool, capped to the MTU the GTP-U tunnel leaves.
*/}}
{{- define "ims.ueroute" -}}
- name: ueroute
  image: {{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- with .Values.sidecar.resources }}
  resources: {{- toYaml . | nindent 4 }}
  {{- end }}
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
    via={{ .Values.global.ue.via | quote }}

    while :; do
      if [ -n "$via" ]; then
        # An explicit next hop: the kernel resolves the device from it, which
        # is the Gm one whenever that is the interface the hop is on-link on.
        ip route replace "$pool" via "$via" mtu "$mtu"
      else
        # "default via <gw> dev <dev>" -> "<gw> <dev>"
        set -- $(ip route | awk '$1 == "default" { print $3, $5; exit }')
        if [ -n "$1" ]; then
          ip route replace "$pool" via "$1" dev "$2" mtu "$mtu"
        fi
      fi
      sleep {{ .Values.reconcile }}
    done
{{- end }}

{{/*
The test UE's environment: the access it attaches over (S5/S8 to the core's
SMF, GTP-U on the pod's own interface) and the subscriber it registers as.
Shared by every helm test hook, so they all attach the same way and as the
same provisioned IMSI range -- the core provisions `subscribers.count` of
them, one by default, and a hook that registered as anybody else would be
testing the HSS rather than the IMS.
*/}}
{{- define "ims.test.env" -}}
- {name: PGW_IP,           value: {{ .Values.global.core.release }}-smf.{{ .Release.Namespace }}.svc.cluster.local}
- {name: GTPU_IFACE,       value: eth0}
- {name: GTPU_INNER_IFACE, value: eth0}
{{- with .Values.test.t3ms }}
- {name: GTP_T3_MS,        value: {{ . | quote }}}
{{- end }}
- {name: IMS_K,     value: {{ .Values.test.k | quote }}}
- {name: IMS_OPC,   value: {{ .Values.test.opc | quote }}}
- {name: IMS_MCC,   value: {{ .Values.mcc | quote }}}
- {name: IMS_MNC,   value: {{ .Values.mnc | quote }}}
- {name: IMS_REALM, value: {{ include "ims.realm.ims" . | quote }}}
- {name: IMS_IMSI,  value: {{ tpl .Values.test.imsi . | quote }}}
- {name: IMS_MSISDN_CC,     value: {{ tpl .Values.test.msisdn.cc . | quote }}}
- {name: IMS_MSISDN_DIGITS, value: {{ .Values.test.msisdn.digits | quote }}}
- {name: CALL_URI, value: {{ .Values.test.uri | quote }}}
{{- end }}

{{/*
What the test UE needs of the kernel: NET_ADMIN for the ESP SAs and policies,
the transparent UE socket and the TC hook; BPF to load the GTP-U datapath the
user plane rides.
*/}}
{{- define "ims.test.securityContext" -}}
capabilities:
  add:
  - NET_ADMIN
  - BPF
  - PERFMON
{{- end }}
