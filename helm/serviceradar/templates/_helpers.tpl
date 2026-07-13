{{- define "serviceradar.fullname" -}}
{{- printf "serviceradar" -}}
{{- end -}}

{{/*
Get image tag for a service.
Uses global.imageTag if set, otherwise falls back to the service-specific tag.
Usage: {{ include "serviceradar.imageTag" (dict "Values" .Values "service" "core") }}
*/}}
{{- define "serviceradar.imageTag" -}}
{{- $global := .Values.global | default dict -}}
{{- $globalTag := $global.imageTag | default "" -}}
{{- if $globalTag -}}
{{- $globalTag -}}
{{- else -}}
{{- index .Values.image.tags .service -}}
{{- end -}}
{{- end -}}

{{/*
Get the base registry/repository prefix for first-party ServiceRadar images.
*/}}
{{- define "serviceradar.imageRegistry" -}}
{{- $image := .Values.image | default dict -}}
{{- trimSuffix "/" (default "registry.carverauto.dev/serviceradar" $image.registry) -}}
{{- end -}}

{{/*
Build a first-party ServiceRadar image repository.
Usage: {{ include "serviceradar.imageRepository" (dict "Values" .Values "name" "serviceradar-web-ng") }}
*/}}
{{- define "serviceradar.imageRepository" -}}
{{- printf "%s/%s" (include "serviceradar.imageRegistry" .) .name -}}
{{- end -}}

{{/*
Build an image ref suffix for a service.
Uses image.digests.<service> when set, otherwise falls back to :tag behavior.
Usage: {{ include "serviceradar.imageRepository" (dict "Values" .Values "name" "serviceradar-core-elx") }}{{ include "serviceradar.imageRefSuffix" (dict "Values" .Values "service" "core") }}
*/}}
{{- define "serviceradar.imageRefSuffix" -}}
{{- $image := .Values.image | default dict -}}
{{- $digests := $image.digests | default dict -}}
{{- $digest := index $digests .service | default "" -}}
{{- if $digest -}}
{{- if hasPrefix "@" $digest -}}
{{- $digest -}}
{{- else -}}
{{- printf "@%s" $digest -}}
{{- end -}}
{{- else -}}
{{- printf ":%s" (include "serviceradar.imageTag" .) -}}
{{- end -}}
{{- end -}}

{{/*
Build a full first-party ServiceRadar image reference.
Usage: {{ include "serviceradar.imageRef" (dict "Values" .Values "name" "serviceradar-core-elx" "service" "core") }}
*/}}
{{- define "serviceradar.imageRef" -}}
{{- printf "%s%s" (include "serviceradar.imageRepository" .) (include "serviceradar.imageRefSuffix" .) -}}
{{- end -}}

{{/*
Build the default ServiceRadar CNPG image name. cnpg.imageName can still override
the full ref when a deployment needs a bespoke database image.
*/}}
{{- define "serviceradar.cnpgImageName" -}}
{{- $cnpg := .cnpg | default (default dict .Values.cnpg) -}}
{{- if $cnpg.imageName -}}
{{- $cnpg.imageName -}}
{{- else -}}
{{- /* Default to the known-good 18.3.0-sr5 build (digest c349a1d). The c70e6cf6
       re-push of 18.3.0-sr5 is a BROKEN build (timescaledb needs GLIBC_2.38; it
       crash-loops) — the 2026-06-17 demo CNPG outage. Do NOT repin to c70e6cf6. */ -}}
{{- printf "%s:%s" (include "serviceradar.imageRepository" (dict "Values" .Values "name" "serviceradar-cnpg")) (default "18.3.0-sr5@sha256:c349a1d34aef056f818630e0766501b5c98fa7598bdeee38d59d677a94cb18c9" $cnpg.imageTag) -}}
{{- end -}}
{{- end -}}

{{/*
Get image pull policy.
Uses global.imagePullPolicy if set, otherwise defaults to IfNotPresent.
Usage: {{ include "serviceradar.imagePullPolicy" . }}
*/}}
{{- define "serviceradar.imagePullPolicy" -}}
{{- $global := .Values.global | default dict -}}
{{- $global.imagePullPolicy | default "IfNotPresent" -}}
{{- end -}}

{{- define "serviceradar.imagePullSecrets" -}}
{{- if .Values.image.registryPullSecret }}
imagePullSecrets:
  - name: {{ .Values.image.registryPullSecret | quote }}
{{- end }}
{{- end -}}

{{/*
Render a Kubernetes NetworkPolicy ports list from values entries shaped as:
  - protocol: TCP
    port: 50052
    endPort: 50060 # optional
*/}}
{{- define "serviceradar.networkPolicyPorts" -}}
{{- range . }}
- protocol: {{ default "TCP" .protocol }}
  port: {{ .port }}
  {{- if .endPort }}
  endPort: {{ .endPort }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "serviceradar.runtimeCertsSecretName" -}}
{{- default "serviceradar-runtime-certs" .Values.certs.runtimeSecretName -}}
{{- end -}}

{{/*
Pod-template annotations that force cert consumers to roll when the managed
runtime cert layout version changes.
*/}}
{{- define "serviceradar.runtimeCertRollAnnotations" -}}
serviceradar.io/runtime-cert-layout-version: {{ default "1" (default (dict) .Values.certs).runtimeLayoutVersion | quote }}
{{- end -}}

{{- define "serviceradar.kvEnv" -}}
{{- $vals := .Values -}}
{{- $trustDomain := default $vals.spire.trustDomain $vals.kv.trustDomain -}}
{{- $serverID := include "serviceradar.kvServerSPIFFEID" . -}}
{{- if not $vals.kv.enabled }}
{{- else }}
- name: CONFIG_SOURCE
  value: "file"
- name: KV_ADDRESS
  value: "{{ default "serviceradar-datasvc:50057" $vals.kv.address }}"
- name: KV_SEC_MODE
  value: "{{ default "mtls" $vals.kv.secMode }}"
- name: KV_TRUST_DOMAIN
  value: "{{ $trustDomain }}"
- name: KV_SERVER_SPIFFE_ID
  value: "{{ $serverID }}"
- name: KV_WORKLOAD_SOCKET
  value: "{{ default "unix:/run/spire/sockets/agent.sock" $vals.kv.workloadSocket }}"
- name: KV_CERT_DIR
  value: "{{ default "/etc/serviceradar/certs" $vals.kv.certDir }}"
{{- end }}
{{- end -}}
{{- define "serviceradar.configSyncEnv" -}}
{{- $cfg := merge (dict "enabled" true "seed" true "watch" false "kvKey" "" "role" "" "extraArgs" "" "extraEnv" (dict)) (default (dict) .cfg) -}}
- name: CONFIG_SYNC_ENABLED
  value: "{{ ternary "true" "false" $cfg.enabled }}"
- name: CONFIG_SYNC_SEED
  value: "{{ ternary "true" "false" $cfg.seed }}"
- name: CONFIG_SYNC_WATCH
  value: "{{ ternary "true" "false" $cfg.watch }}"
{{- if $cfg.kvKey }}
- name: CONFIG_KV_KEY
  value: {{ $cfg.kvKey | quote }}
{{- end }}
{{- if $cfg.role }}
- name: CONFIG_SYNC_ROLE
  value: {{ $cfg.role | quote }}
{{- end }}
{{- if $cfg.extraArgs }}
- name: CONFIG_SYNC_EXTRA_ARGS
  value: {{ $cfg.extraArgs | quote }}
{{- end }}
{{- if $cfg.extraEnv }}
{{- range $name, $value := $cfg.extraEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "serviceradar.kvServerSPIFFEID" -}}
{{- $vals := .Values -}}
{{- $ns := default .Release.Namespace $vals.spire.namespace -}}
{{- $datasvcSA := default "serviceradar-datasvc" $vals.spire.datasvcServiceAccount -}}
{{- $trustDomain := default $vals.spire.trustDomain $vals.kv.trustDomain -}}
{{- default (printf "spiffe://%s/ns/%s/sa/%s" $trustDomain $ns $datasvcSA) $vals.kv.serverSPIFFEID -}}
{{- end -}}

{{- define "serviceradar.coreServerSPIFFEID" -}}
{{- $vals := .Values -}}
{{- $ns := default .Release.Namespace $vals.spire.namespace -}}
{{- $trustDomain := default $vals.spire.trustDomain $vals.coreClient.trustDomain -}}
{{- $coreSA := default "serviceradar-core" $vals.spire.coreServiceAccount -}}
{{- default (printf "spiffe://%s/ns/%s/sa/%s" $trustDomain $ns $coreSA) $vals.coreClient.serverSPIFFEID -}}
{{- end -}}

{{- define "serviceradar.coreAddress" -}}
{{- $vals := .Values -}}
{{- $ns := default .Release.Namespace $vals.spire.namespace -}}
{{- default (printf "serviceradar-core.%s.svc.cluster.local:50052" $ns) $vals.coreClient.address -}}
{{- end -}}

{{- define "serviceradar.coreEnv" -}}
{{- $vals := .Values -}}
{{- $ns := default .Release.Namespace $vals.spire.namespace -}}
{{- $trustDomain := default $vals.spire.trustDomain $vals.coreClient.trustDomain -}}
{{- $coreSA := default "serviceradar-core" $vals.spire.coreServiceAccount -}}
{{- $serverID := default (printf "spiffe://%s/ns/%s/sa/%s" $trustDomain $ns $coreSA) $vals.coreClient.serverSPIFFEID -}}
- name: CORE_ADDRESS
  value: "{{ include "serviceradar.coreAddress" . }}"
- name: CORE_SEC_MODE
  value: "{{ default "mtls" $vals.coreClient.secMode }}"
- name: CORE_TRUST_DOMAIN
  value: "{{ $trustDomain }}"
- name: CORE_SERVER_SPIFFE_ID
  value: "{{ $serverID }}"
- name: CORE_WORKLOAD_SOCKET
  value: "{{ default "unix:/run/spire/sockets/agent.sock" $vals.coreClient.workloadSocket }}"
- name: CORE_CERT_DIR
  value: "{{ default "/etc/serviceradar/certs" $vals.coreClient.certDir }}"
{{- end -}}

{{/*
Topology spread constraints to distribute replicas of one workload across nodes.
Enabled when .Values.topologySpread.enabled is true.
Usage: {{ include "serviceradar.topologySpread" (dict "root" . "app" "serviceradar-core") | nindent 6 }}
*/}}
{{- define "serviceradar.topologySpread" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- $ts := default (dict) $root.Values.topologySpread -}}
{{- if $ts.enabled }}
topologySpreadConstraints:
  - maxSkew: {{ $ts.maxSkew | default 1 }}
    topologyKey: {{ $ts.topologyKey | default "kubernetes.io/hostname" }}
    whenUnsatisfiable: {{ $ts.whenUnsatisfiable | default "ScheduleAnyway" }}
    labelSelector:
      matchLabels:
        app: {{ $app | quote }}
{{- end }}
{{- end -}}

{{- define "serviceradar.spireSocketHostPath" -}}
{{- $vals := .Values -}}
{{- $ns := default .Release.Namespace $vals.spire.namespace -}}
{{- if $vals.spire.socketHostPath }}
{{- $vals.spire.socketHostPath }}
{{- else }}
{{- printf "/run/spire/%s/sockets" $ns }}
{{- end -}}
{{- end -}}

{{- /* RBAC helper names to avoid clashes across namespaces */ -}}
{{- define "serviceradar.spireAgentClusterRoleName" -}}
{{- printf "%s-%s-%s" (include "serviceradar.fullname" .) .Release.Namespace "spire-agent-cluster-role" -}}
{{- end -}}

{{- define "serviceradar.spireAgentClusterRoleBindingName" -}}
{{- printf "%s-%s-%s" (include "serviceradar.fullname" .) .Release.Namespace "spire-agent-cluster-role-binding" -}}
{{- end -}}

{{- define "serviceradar.spireServerTrustRoleName" -}}
{{- printf "%s-%s-%s" (include "serviceradar.fullname" .) .Release.Namespace "spire-server-trust-role" -}}
{{- end -}}

{{- define "serviceradar.spireServerTrustRoleBindingName" -}}
{{- printf "%s-%s-%s" (include "serviceradar.fullname" .) .Release.Namespace "spire-server-trust-role-binding" -}}
{{- end -}}

{{- define "serviceradar.spireControllerManagerRoleName" -}}
{{- printf "%s-%s-%s" (include "serviceradar.fullname" .) .Release.Namespace "spire-controller-manager" -}}
{{- end -}}

{{- define "serviceradar.spireControllerManagerRoleBindingName" -}}
{{- printf "%s-%s-%s" (include "serviceradar.fullname" .) .Release.Namespace "spire-controller-manager-binding" -}}
{{- end -}}

{{/*
Restricted-compliant pod-level securityContext.
Usage: {{- include "serviceradar.podSecurityContext" . | nindent 6 }}
*/}}
{{- define "serviceradar.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  runAsGroup: 1001
  fsGroup: 1001
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{/*
Restricted-compliant pod securityContext for Elixir release images.
The release root under /app is owned by the image runtime UID.
*/}}
{{- define "serviceradar.elixirReleasePodSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{/*
Restricted-compliant container-level securityContext.
Usage: {{- include "serviceradar.containerSecurityContext" . | nindent 10 }}
*/}}
{{- define "serviceradar.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end -}}

{{/*
Container securityContext with NET_RAW for workloads that need raw network sockets.
This is not Pod Security Baseline compliant.
Usage: {{- include "serviceradar.networkContainerSecurityContext" . | nindent 10 }}
*/}}
{{- define "serviceradar.networkContainerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsUser: 0
  runAsNonRoot: false
  capabilities:
    add: ["NET_RAW"]
{{- end -}}

{{/*
Restricted-compliant container securityContext with NET_BIND_SERVICE (for low ports).
Usage: {{- include "serviceradar.bindServiceContainerSecurityContext" . | nindent 10 }}
*/}}
{{- define "serviceradar.bindServiceContainerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]
{{- end -}}

{{/*
Restricted-compliant container securityContext for root-based utility images by
forcing an explicit non-root UID/GID aligned with the ServiceRadar runtime user.
Usage: {{- include "serviceradar.nonRootContainerSecurityContext" . | nindent 10 }}
*/}}
{{- define "serviceradar.nonRootContainerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsUser: 1001
  runAsGroup: 1001
  capabilities:
    drop: ["ALL"]
{{- end -}}

{{/*
Generate checksum for db credentials to trigger pod restart when secret changes.
Uses lookup to get current secret value, falls back to random if not found.
*/}}
{{- define "serviceradar.dbCredentialsChecksum" -}}
{{- $ns := default .Release.Namespace .Values.spire.namespace -}}
{{- $cnpg := default (dict) .Values.cnpg -}}
{{- $secretName := default "serviceradar-db-credentials" $cnpg.credentialsSecret -}}
{{- $superSecretName := default "cnpg-superuser" $cnpg.superuserSecret -}}
{{- $existingSecret := (lookup "v1" "Secret" $ns $secretName) -}}
{{- $existingSuperSecret := (lookup "v1" "Secret" $ns $superSecretName) -}}
{{- $secretPayload := "" -}}
{{- if and $existingSecret $existingSecret.data -}}
{{- $secretPayload = printf "%s%s" $secretPayload ($existingSecret.data | toJson) -}}
{{- end -}}
{{- if and $existingSuperSecret $existingSuperSecret.data -}}
{{- $secretPayload = printf "%s%s" $secretPayload ($existingSuperSecret.data | toJson) -}}
{{- end -}}
{{- if ne $secretPayload "" -}}
{{- $secretPayload | sha256sum -}}
{{- else -}}
{{- randAlphaNum 32 | sha256sum -}}
{{- end -}}
{{- end -}}

{{/*
CNPG cluster and connection endpoint helpers.

The direct host is used for migrations, bootstrap, DDL, and any client that is
not transaction-pooler safe. The pooler host is used only by workload templates
that opt into cnpg.pooler.route.<workload>.
*/}}
{{- define "serviceradar.cnpgClusterName" -}}
{{- $cnpg := default (dict) .Values.cnpg -}}
{{- default "cnpg" $cnpg.clusterName -}}
{{- end -}}

{{- define "serviceradar.cnpgDirectHost" -}}
{{- $cnpg := default (dict) .Values.cnpg -}}
{{- $clusterName := include "serviceradar.cnpgClusterName" . -}}
{{- default (printf "%s-rw.%s.svc.cluster.local" $clusterName .Release.Namespace) $cnpg.host -}}
{{- end -}}

{{- define "serviceradar.cnpgPoolerName" -}}
{{- $cnpg := default (dict) .Values.cnpg -}}
{{- $pooler := default (dict) $cnpg.pooler -}}
{{- $clusterName := include "serviceradar.cnpgClusterName" . -}}
{{- default (printf "%s-pooler-rw" $clusterName) $pooler.name -}}
{{- end -}}

{{- define "serviceradar.cnpgPoolerHost" -}}
{{- $cnpg := default (dict) .Values.cnpg -}}
{{- $pooler := default (dict) $cnpg.pooler -}}
{{- $poolerName := include "serviceradar.cnpgPoolerName" . -}}
{{- default (printf "%s.%s.svc.cluster.local" $poolerName .Release.Namespace) $pooler.host -}}
{{- end -}}

{{- define "serviceradar.cnpgWorkloadHost" -}}
{{- $root := .root -}}
{{- $workload := .workload -}}
{{- $cnpg := default (dict) $root.Values.cnpg -}}
{{- $pooler := default (dict) $cnpg.pooler -}}
{{- $route := default (dict) $pooler.route -}}
{{- $routeWorkload := default false (get $route $workload) -}}
{{- if and (default false $pooler.enabled) $routeWorkload -}}
{{- include "serviceradar.cnpgPoolerHost" $root -}}
{{- else -}}
{{- include "serviceradar.cnpgDirectHost" $root -}}
{{- end -}}
{{- end -}}

{{- define "serviceradar.gatewayApiEnvoyProxyName" -}}
{{- printf "%s-%s-edge" (include "serviceradar.fullname" .) .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiGatewayClassName" -}}
{{- printf "%s-%s-envoy" (include "serviceradar.fullname" .) .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiGatewayName" -}}
{{- printf "%s-edge-gateway" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiRouteName" -}}
{{- printf "%s-edge-route" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiStreamingRouteName" -}}
{{- printf "%s-camera-stream-route" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiRedirectRouteName" -}}
{{- printf "%s-edge-http-redirect" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiCertificateName" -}}
{{- printf "%s-edge-tls" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiBackendTrafficPolicyName" -}}
{{- printf "%s-edge-policy" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.gatewayApiStreamingBackendTrafficPolicyName" -}}
{{- printf "%s-camera-stream-policy" (include "serviceradar.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fail chart rendering when callback execution is enabled without its exact reviewed contract. */}}
{{- define "serviceradar.validateAutomationCallbacks" -}}
{{- $callbacks := default (dict) .Values.automationCallbacks -}}
{{- $enabled := false -}}
{{- if hasKey $callbacks "enabled" -}}{{- $enabled = get $callbacks "enabled" -}}{{- end -}}
{{- if $enabled -}}
  {{- if le (int (default 0 $callbacks.awxCredentialTypeId)) 0 -}}
    {{- fail "automationCallbacks.awxCredentialTypeId must be a positive AWX credential type ID when automationCallbacks.enabled=true" -}}
  {{- end -}}
  {{- if le (int (default 0 $callbacks.awxOrganizationId)) 0 -}}
    {{- fail "automationCallbacks.awxOrganizationId must be a positive AWX organization ID when automationCallbacks.enabled=true" -}}
  {{- end -}}
  {{- if not (regexMatch "^[0-9a-f]{64}$" (default "" $callbacks.awxInjectorDigest)) -}}
    {{- fail "automationCallbacks.awxInjectorDigest must be the lowercase SHA-256 of the reviewed AWX injector when automationCallbacks.enabled=true" -}}
  {{- end -}}
  {{- $responsePolicy := default (dict) $callbacks.responsePolicy -}}
  {{- if eq (default "" $responsePolicy.existingSecretName) "" -}}
    {{- fail "automationCallbacks.responsePolicy.existingSecretName is required when automationCallbacks.enabled=true" -}}
  {{- end -}}
  {{- if eq (default "" $responsePolicy.secretKey) "" -}}
    {{- fail "automationCallbacks.responsePolicy.secretKey is required when automationCallbacks.enabled=true" -}}
  {{- end -}}
{{- end -}}
{{- end -}}
