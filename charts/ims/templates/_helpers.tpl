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

{{- define "ims.identity" -}}
- name: identity
  image: {{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- with .Values.sidecar.resources }}
  resources: {{- toYaml . | nindent 4 }}
  {{- end }}
  env:
  - name: INSTANCE
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
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
The Gm NetworkAttachmentDefinition's name, release-prefixed.

A NAD is a namespaced object and `gm.name` is the same string in every release,
so without the prefix two releases in one namespace write the same object: the
second install fails on an ownership conflict, and an upgrade of either one
silently re-points the other release's P-CSCF at a different subnet. The
release name is the prefix, as it is for every other object this chart owns.

Call with the root context.
*/}}
{{- define "ims.gm.name" -}}
{{- printf "%s-%s" .Release.Name .Values.gm.name -}}
{{- end }}

{{/*
One entry for the `k8s.v1.cni.cncf.io/networks` annotation.

The JSON list form rather than the bare "name" string, because only the list
form carries `interface`, and the device name is what
images/kamailio/cscf/start.sh reads `ipsec_listen_addr` off. Left to Multus it
would be `net1`, `net2`, ... in attachment order -- stable only as long as
nothing else is attached to the same pod.

The name here is the rendered one, not `gm.name`: this annotation and the
object above are the two halves that cannot drift.

Call with the root context.
*/}}
{{- define "ims.networks" -}}
{{- list (dict "name" (include "ims.gm.name" .) "interface" .Values.gm.interface) | toJson -}}
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
{{- toJson (merge (deepCopy .Values.gm.config) (dict "name" (include "ims.gm.name" .))) -}}
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
