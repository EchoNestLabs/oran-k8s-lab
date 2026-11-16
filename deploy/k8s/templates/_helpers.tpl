{{/*
Shared helpers for the oran-rfsim-lab chart.
*/}}

{{- define "oran-lab.name" -}}
{{- printf "%s" .Chart.Name -}}
{{- end -}}

{{- define "oran-lab.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified component name: <release>-<component> */}}
{{- define "oran-lab.component" -}}
{{- printf "%s-%s" .Release.Name .ctx.Values.component -}}
{{- end -}}

{{/*
Standard labels. Pass component explicitly: .component (string), NOT via
.Values.component - selectors must match template labels byte-for-byte.
Usage: include "oran-lab.labels" (dict "ctx" $ "component" "amf")
*/}}
{{- define "oran-lab.labels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/part-of: oran-rfsim-lab
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end -}}

{{/* Selector labels (subset, for matchLabels). Same dict contract as labels. */}}
{{- define "oran-lab.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/*
Downward-API pod IP injection block. Include inside a container env list.
Requires .ctx.Values.podIpEnvVar (name of the env var the entrypoint reads).
Usage:  env: {{ include "oran-lab.podip" (dict "ctx" . "podIpEnvVar" "BIND_IP") }}
Then the entrypoint uses $BIND_IP instead of guessing an interface address.
*/}}
{{- define "oran-lab.podip" -}}
- name: {{ .podIpEnvVar }}
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
{{- end -}}

{{/*
Init-container that waits until an A record resolves AND (optionally) a TCP
port accepts. Deliberately uses an exec script, never a tcpSocket probe on
rfsim 4043 (a probe dial looks like a UE and can disturb the gNB).
Params: ctx, waitName, waitHost, waitPort (optional), waitImage.
*/}}
{{- define "oran-lab.waitfor" -}}
- name: {{ .waitName }}
  image: {{ .waitImage | default "busybox:1.36" }}
  command: ["sh", "-c"]
  args:
    - |
      {{- $fqdn := printf "%s.%s.svc.cluster.local" .waitHost .ctx.Release.Namespace }}
      echo "waiting for {{ $fqdn }}{{ if .waitPort }}:{{ .waitPort }}{{ end }}"
      while true; do
        nslookup {{ $fqdn }} >/dev/null 2>&1 || { sleep 2; continue; }
        {{- if and .waitPort (ne .waitProto "sctp") }}
        nc -z {{ $fqdn }} {{ .waitPort }} >/dev/null 2>&1 && break || sleep 2
        {{- else }}
        # SCTP ports cannot be probed with busybox nc (TCP-only). Headless
        # endpoints exist once the pod is Running and NGAP binds at start.
        break
        {{- end }}
      done
      echo "ready: {{ .waitHost }}{{ if .waitPort }}:{{ .waitPort }}{{ end }}"
{{- end -}}
