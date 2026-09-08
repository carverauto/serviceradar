{{/*
Expand the name of the chart.
*/}}
{{- define "sr-edge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sr-edge.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "sr-edge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sr-edge.labels" -}}
helm.sh/chart: {{ include "sr-edge.chart" . }}
{{ include "sr-edge.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: serviceradar-k8s-edge
{{- end }}

{{- define "sr-edge.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sr-edge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sr-edge.agentServiceAccountName" -}}
{{- if .Values.serviceAccount.agent.create }}
{{- default (printf "%s-agent" (include "sr-edge.fullname" .)) .Values.serviceAccount.agent.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.agent.name }}
{{- end }}
{{- end }}

{{- define "sr-edge.inventoryServiceAccountName" -}}
{{- if .Values.serviceAccount.inventory.create }}
{{- default (printf "%s-k8s-inventory" (include "sr-edge.fullname" .)) .Values.serviceAccount.inventory.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.inventory.name }}
{{- end }}
{{- end }}

{{- define "sr-edge.image" -}}
{{- $registry := .Values.global.imageRegistry | trimSuffix "/" -}}
{{- $name := .name -}}
{{- $tag := default .Values.global.imageTag .tag -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end }}

{{- define "sr-edge.clusterId" -}}
{{- $id := .Values.clusterId | default "" | trim -}}
{{- if and .Values.k8sInventory.enabled (eq $id "") -}}
{{- fail "clusterId is required when k8sInventory.enabled is true (use a durable id such as acme-prod-eks)" -}}
{{- end -}}
{{- $id -}}
{{- end }}

{{- define "sr-edge.validate" -}}
{{- if .Values.agent.enabled -}}
  {{- if eq (.Values.agent.gatewayAddress | default "" | trim) "" -}}
    {{- fail "agent.gatewayAddress is required when agent.enabled is true" -}}
  {{- end -}}
  {{- if eq (.Values.agent.existingTlsSecret | default "" | trim) "" -}}
    {{- fail "agent.existingTlsSecret is required when agent.enabled is true (Secret with enrollment mTLS materials)" -}}
  {{- end -}}
{{- end -}}
{{- if and .Values.k8sInventory.enabled (not .Values.agent.enabled) (eq .Values.k8sInventory.publishMode "agent_spool") -}}
  {{- fail "k8sInventory.publishMode=agent_spool requires agent.enabled=true (or use publishMode=stdout for lab)" -}}
{{- end -}}
{{- end }}

{{/*
The one spool directory shared by the k8s-inventory collector and the agent.

These are two containers in one pod writing and reading the SAME emptyDir, so the path has to
agree. It was configured twice -- k8sInventory.spoolDir for the collector, and
agent.k8sInventorySpoolDir for the agent's mount and its config file -- with equal defaults and
nothing tying them together. Overriding one alone mounts the same volume at two paths, which is
not an error at any layer: the collector writes snapshots, the agent watches an empty directory,
and the pipeline goes quiet with every container healthy.

k8sInventory.spoolDir is authoritative because the collector owns the data. agent.
k8sInventorySpoolDir is still honoured so existing values files keep working, but it must agree.
*/}}
{{- define "sr-edge.k8sInventorySpoolDir" -}}
{{- $collector := .Values.k8sInventory.spoolDir | default "" | trim -}}
{{- $agent := .Values.agent.k8sInventorySpoolDir | default "" | trim -}}
{{- if eq $collector "" -}}
  {{- fail "k8sInventory.spoolDir must not be empty: it is the shared spool path the agent reads" -}}
{{- end -}}
{{- if and (ne $agent "") (ne $agent $collector) -}}
  {{- fail (printf "agent.k8sInventorySpoolDir (%s) must equal k8sInventory.spoolDir (%s): both name the same shared emptyDir, and a mismatch silently stops inventory from reaching the agent. Set only k8sInventory.spoolDir." $agent $collector) -}}
{{- end -}}
{{- $collector -}}
{{- end }}
