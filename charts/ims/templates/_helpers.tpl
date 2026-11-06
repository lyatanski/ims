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
The Diameter identity, `<pod name>.<ims realm>`: `<release>-<role>-<ordinal>`,
the names core's ConnectPeer list enumerates.
*/}}
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
{{- $valkey := printf "-h %s -p %v" (include "valkey.name" .root.Subcharts.trgw.Subcharts.valkey) .root.Values.trgw.valkey.ports.valkey }}
- name: wait-store
  image: {{ .root.Values.trgw.valkey.image.repository }}:{{ .root.Values.trgw.valkey.image.tag }}
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

{{/*
The emergency numbers the P-CSCF and the E-CSCF share (cscf/sos.cfg), left
out when unset so the cfg's own default (112, 911) applies.
*/}}
{{- define "ims.sosnum" -}}
{{- with .Values.cscf.emergency.numbers }}
- name: SOSNUM
  value: {{ join " " . | quote }}
{{- end }}
{{- end }}

{{- define "ims.regsrv" -}}
addr={{ template "valkey.name" .Subcharts.trgw.Subcharts.valkey }};port={{ .Values.trgw.valkey.ports.valkey }};db={{ .Values.db.interrogating }}
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
The IBCF's SIP URI with cscf.border on, empty without it. The CSCFs' default
exit towards other networks and the trunk.
*/}}
{{- define "ims.ibcf" -}}
{{- if .Values.cscf.border.enabled -}}
sip:ibcf.{{ include "ims.realm.ims" . }}
{{- end -}}
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

Call with (dict "root" $ "name" <gm|ici> "config" <its config>).
*/}}
{{- define "ims.network.config" -}}
{{- toJson (merge (deepCopy .config) (dict "name" (printf "%s-%s" .root.Release.Name .name))) -}}
{{- end }}

{{/*
The Ici networks, as JSON {"nets": [...]}: `ici.networks`, or without it the
single unnamed one `ici.interface`, `ici.addresses` and `ici.config` describe.
Each entry adds what the rest of the chart derives from the name:
  sfx   "" or "-<name>": the suffix of its sockets in cscf/border.cfg ("Ici",
        "IciT"), of its TrGW templates and of its NetworkAttachmentDefinition
  nad   the NetworkAttachmentDefinition, <release>-ici<sfx>
The one IBCF is on every network, at every address listed for it.
*/}}
{{- define "ims.ici.networks" -}}
{{- $in := .Values.ici.networks }}
{{- if not $in }}
{{- $in = list (dict "name" "" "interface" .Values.ici.interface "addresses" .Values.ici.addresses "config" .Values.ici.config) }}
{{- end }}
{{- $out := list }}
{{- $names := list }}
{{- range $k, $net := $in }}
{{- if and (hasKey $net "name") (not (kindIs "string" $net.name)) }}{{ fail (printf "ici.networks[%d]: name %v is not a string (quote it: YAML reads y, n, on, off as booleans)" $k $net.name) }}{{ end }}
{{- $name := $net.name | default "" }}
{{- if and (gt (len $in) 1) (not $name) }}{{ fail (printf "ici.networks[%d]: a name is required" $k) }}{{ end }}
{{- if and $name (not (regexMatch "^[a-z0-9]+$" $name)) }}{{ fail (printf "ici.networks[%d]: %q is not [a-z0-9]+" $k $name) }}{{ end }}
{{- if has $name $names }}{{ fail (printf "ici.networks: %q twice" $name) }}{{ end }}
{{- $names = append $names $name }}
{{- if not $net.interface }}{{ fail (printf "ici.networks[%d] (%s): no interface" $k $name) }}{{ end }}
{{- if gt (len $net.interface) 15 }}{{ fail (printf "ici.networks[%d] (%s): interface %q is over 15 characters" $k $name $net.interface) }}{{ end }}
{{- if not $net.addresses }}{{ fail (printf "ici.networks[%d] (%s): no addresses" $k $name) }}{{ end }}
{{- range $a := $net.addresses }}
{{- if or (not (contains "/" $a)) (contains ":" $a) }}
{{- fail (printf "ici: %q is not an IPv4 address with its prefix length" $a) }}
{{- end }}
{{- end }}
{{- $sfx := ternary (printf "-%s" $name) "" (ne $name "") }}
{{- $out = append $out (dict "name" $name "sfx" $sfx "nad" (printf "%s-ici%s" $.Release.Name $sfx) "interface" $net.interface "addresses" $net.addresses "config" $net.config) }}
{{- end }}
{{- toJson (dict "nets" $out) -}}
{{- end }}

{{/*
The Gm attachment, as JSON: `gm.addresses` split by family into `v4` (required,
IPSEC) and `v6` (optional, IPSEC6), with the list itself as `ips`, and
`gm.gateways` the same way into `gw` and `gw6`, each the next hop to that
family's UE pool. `{}` while Gm is off.
*/}}
{{- define "ims.gm" -}}
{{- $root := . }}
{{- $out := dict }}
{{- if .Values.gm.enabled }}
{{- $_ := set $out "ips" (required "gm.addresses: the P-CSCF's Gm addresses" .Values.gm.addresses) }}
{{- range $out.ips }}
{{- if not (contains "/" .) }}{{ fail (printf "gm.addresses: %s has no prefix length" .) }}{{ end }}
{{- $k := ternary "v6" "v4" (contains ":" .) }}
{{- if hasKey $out $k }}{{ fail (printf "gm.addresses: one %s address at most" (ternary "IPv6" "IPv4" (eq $k "v6"))) }}{{ end }}
{{- $_ := set $out $k . }}
{{- end }}
{{- if not $out.v4 }}{{ fail "gm.addresses: an IPv4 address is required, it is what IPSEC binds" }}{{ end }}
{{- range .Values.gm.gateways }}
{{- if contains "/" . }}{{ fail (printf "gm.gateways: %s is an address, not a prefix" .) }}{{ end }}
{{- $k := ternary "gw6" "gw" (contains ":" .) }}
{{- if hasKey $out $k }}{{ fail (printf "gm.gateways: one %s gateway at most" (ternary "IPv6" "IPv4" (eq $k "gw6"))) }}{{ end }}
{{- $_ := set $out $k . }}
{{- end }}
{{- if and $root.Values.global.ue.subnet (not $out.gw) }}{{ fail "gm.gateways: an IPv4 gateway is required, the next hop to global.ue.subnet" }}{{ end }}
{{- if and $out.v6 $root.Values.global.ue.subnet6 (not $out.gw6) }}{{ fail "gm.gateways: an IPv6 gateway is required with an IPv6 address, the next hop to global.ue.subnet6" }}{{ end }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/*
`gm.config` plus the route to the UE pool, so that CNI installs it when it
configures the interface. One route per family, through `gm.gateways`, and only
the IPv6 one while the P-CSCF has an IPv6 address. The MTU the GTP-U tunnel
leaves (`global.ue.mtu`) is the interface's own `mtu`, unless the config sets
one: CNI's route type has an `mtu`, but the bridge and macvlan plugins (v1.9.1)
add routes with priority, table and scope only and drop it silently. Every
packet on Gm is a UE's, so capping the interface is the same as capping the
route.
*/}}
{{- define "ims.gm.config" -}}
{{- $g := include "ims.gm" . | fromJson }}
{{- $c := deepCopy .Values.gm.config }}
{{- $ipam := $c.ipam | default dict }}
{{- $routes := $ipam.routes | default list }}
{{- with .Values.global.ue.subnet }}
{{- $routes = append $routes (dict "dst" . "gw" $g.gw) }}
{{- end }}
{{- if and $g.v6 .Values.global.ue.subnet6 }}
{{- $routes = append $routes (dict "dst" .Values.global.ue.subnet6 "gw" $g.gw6) }}
{{- end }}
{{- if $routes }}
{{- $_ := set $ipam "routes" $routes }}
{{- end }}
{{- $_ := set $c "ipam" $ipam }}
{{- if not (hasKey $c "mtu") }}
{{- $_ := set $c "mtu" (int .Values.global.ue.mtu) }}
{{- end }}
{{- toJson $c }}
{{- end }}

{{/*
The route to the UE pool through the default route's gateway, capped to the
MTU the GTP-U tunnel leaves -- for a P-CSCF without the Gm attachment, which
carries this route itself when it is there.
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
    pool6={{ .Values.global.ue.subnet6 | quote }}

    # $1 family flag, $2 pool
    route() {
      [ -n "$2" ] || return 0
      # "default via <gw> dev <dev>" -> "<gw> <dev>"
      set -- "$1" "$2" $(ip "$1" route | awk '$1 == "default" { print $3, $5; exit }')
      if [ -n "$3" ]; then
        ip "$1" route replace "$2" via "$3" dev "$4" mtu "$mtu"
      fi
    }

    while :; do
      route -4 "$pool"
      route -6 "$pool6"
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
- {name: IMS_PDN_TYPE, value: {{ .Values.test.pdnType | quote }}}
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
