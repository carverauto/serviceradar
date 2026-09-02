{{- define "serviceradar.fullname" -}}
{{- printf "serviceradar" -}}
{{- end -}}

{{/*
Get image tag for a service.
Uses global.imageTag if set, otherwise falls back to the service-specific tag.
Usage: {{ include "serviceradar.imageTag" (dict "Values" .Values "Chart" .Chart "service" "core") }}
*/}}
{{- define "serviceradar.imageTag" -}}
{{- $global := .Values.global | default dict -}}
{{- $globalTag := $global.imageTag | default "" -}}
{{- $svcTag := index (.Values.image.tags | default dict) .service | default "" -}}
{{- $chartTag := "" -}}
{{- if .Chart -}}
{{- $chartTag = printf "v%s" .Chart.AppVersion -}}
{{- end -}}
{{- $tag := coalesce $globalTag $svcTag $chartTag -}}
{{- if not $tag -}}
{{- fail "serviceradar.imageTag: no tag resolved. Set global.imageTag, image.tags.<service>, or pass Chart so it can default to the chart appVersion." -}}
{{- end -}}
{{- $tag -}}
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
Usage: {{ include "serviceradar.imageRepository" (dict "Values" .Values "Chart" .Chart "name" "serviceradar-web-ng") }}
*/}}
{{- define "serviceradar.imageRepository" -}}
{{- printf "%s/%s" (include "serviceradar.imageRegistry" .) .name -}}
{{- end -}}

{{/*
Build an image ref suffix for a service.
Uses image.digests.<service> when set, otherwise falls back to :tag behavior.
Usage: {{ include "serviceradar.imageRepository" (dict "Values" .Values "Chart" .Chart "name" "serviceradar-core-elx") }}{{ include "serviceradar.imageRefSuffix" (dict "Values" .Values "Chart" .Chart "service" "core") }}
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
Usage: {{ include "serviceradar.imageRef" (dict "Values" .Values "Chart" .Chart "name" "serviceradar-core-elx" "service" "core") }}
*/}}
{{- define "serviceradar.imageRef" -}}
{{- printf "%s%s" (include "serviceradar.imageRepository" .) (include "serviceradar.imageRefSuffix" .) -}}
{{- end -}}

{{/*
The default ServiceRadar CNPG image tag, as tag@digest.

SINGLE SOURCE OF TRUTH. Two templates render a CNPG Cluster -- cnpg-cluster.yaml and
spire-postgres.yaml (which, despite the name, is the cluster definition demo-staging
uses) -- and both used to carry their own copy of this string. They drifted: the main
cluster was bumped while the other stayed on an older pin, so an environment silently
kept running a different PostgreSQL. Both now call this.
*/}}
{{- define "serviceradar.cnpgDefaultImageTag" -}}
18.4.0-sr4@sha256:59e442dec59fac3149e3a3c49ba0cc2987bfb052bca1a0ea8c01b4bb31427d1d
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
{{- /* PostgreSQL 18.4 + TimescaleDB 2.24.0 / PostGIS 3.6.2 / AGE 1.7.0 / pgvector 0.8.2.
       Always pin a digest as well as a tag: a tag alone is mutable, and a broken
       re-push over 18.3.0-sr5 (c70e6cf6, timescaledb needing GLIBC_2.38) let Harbor
       garbage-collect the manifests two live clusters were pinned to -- the
       2026-06-17 demo CNPG outage. Do NOT repin to c70e6cf6, and do not publish
       over an existing tag.

       BEFORE BUMPING THIS, read the extension-version invariant in
       templates/cnpg-extension-update-job.yaml. Briefly: an image ships one
       timescaledb-<version>.so, and Postgres cannot open a database whose catalog
       names a version the image does not carry. The pre-upgrade job converges
       catalogs while the OLD image is still running, so the incoming image's
       TimescaleDB version must be one the outgoing image can update a catalog TO
       (i.e. the outgoing image's default_version). Skipping a release breaks that. */ -}}
{{- printf "%s:%s" (include "serviceradar.imageRepository" (dict "Values" .Values "Chart" .Chart "name" "serviceradar-cnpg")) (default (include "serviceradar.cnpgDefaultImageTag" .) $cnpg.imageTag) -}}
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

{{- define "serviceradar.runtimeIssuerSecretName" -}}
{{- $certs := default dict .Values.certs -}}
{{- default (include "serviceradar.runtimeCertsSecretName" .) (get $certs "issuerSecretName") -}}
{{- end -}}

{{- define "serviceradar.cnpgIssuerSecretName" -}}
{{- $certs := default dict .Values.certs -}}
{{- default (include "serviceradar.runtimeCertsSecretName" .) (get $certs "cnpgIssuerSecretName") -}}
{{- end -}}

{{/*
Render an explicit Kubernetes Secret projection for runtime certificate files.
Every runtime-certificate volume must use this helper so a workload cannot read
CA signing keys or another workload's leaf private key from the shared source
Secret. Callers remain responsible for supplying the smallest key list they
need.
*/}}
{{- define "serviceradar.runtimeCertItems" -}}
{{- range . }}
- key: {{ . | quote }}
  path: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
Hosted runtimes receive their certificate Secret from the control plane. The
presence of the hosted runtime contract is the authoritative hosted-mode
signal; tenant-side certificate generation must stay disabled even if a base
values layer accidentally enables a generator.
*/}}
{{- define "serviceradar.hostedRuntimeEnabled" -}}
{{- $hosted := default dict .Values.hostedRuntime -}}
{{- ternary "true" "false" (ne "" (default "" (get $hosted "contractVersion"))) -}}
{{- end -}}

{{/*
Pod-template annotations that force cert consumers to roll when the managed
runtime cert layout version changes.
*/}}
{{- define "serviceradar.runtimeCertRollAnnotations" -}}
serviceradar.io/runtime-cert-layout-version: {{ default "1" (default (dict) .Values.certs).runtimeLayoutVersion | quote }}
serviceradar.io/runtime-tls-revision: {{ default "initial" (default (dict) .Values.certs).runtimeRevision | quote }}
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
Password from an existing Secret (lookup) or from values. Never random.

Argo CD templates on repo-server, which cannot read namespace Secrets, so
lookup is empty on every sync. randAlphaNum in that path rotated CNPG
credentials and rolled core/web-ng on each apply.
*/}}
{{- define "serviceradar.reuseSecretPassword" -}}
{{- $existing := lookup "v1" "Secret" .namespace .name -}}
{{- if and $existing $existing.data $existing.data.password -}}
{{- b64dec $existing.data.password -}}
{{- else -}}
{{- default "" .fromValues -}}
{{- end -}}
{{- end -}}

{{/*
Generate checksum for db credentials to trigger pod restart when secret changes.
Uses lookup when the renderer can read Secrets. When lookup is empty (Argo
repo-server), stay stable: a random fallback rolls core and web-ng on every
sync. Values passwords still participate so an operator-supplied rotation
rolls the workloads.
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
{{- $valuesPass := default "" $cnpg.password -}}
{{- $valuesSuper := default "" $cnpg.superuserPassword -}}
{{- if or $valuesPass $valuesSuper -}}
{{- printf "%s|%s" $valuesPass $valuesSuper | sha256sum -}}
{{- else -}}
lookup-unavailable
{{- end -}}
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

{{/*
Return the canonical externally reachable web-ng origin.

The accepted root slash is stripped before the value reaches callback and
artifact URL consumers. Explicit ports other than the Endpoint's public HTTPS
port are rejected so PHX_HOST and Endpoint.url cannot disagree.
*/}}
{{- define "serviceradar.webNgPublicUrl" -}}
{{- $webNg := default (dict) .Values.webNg -}}
{{- $publicUrl := trim (default "" $webNg.publicUrl) -}}
{{- if $publicUrl -}}
  {{- $parsed := urlParse $publicUrl -}}
  {{- $scheme := lower (default "" (get $parsed "scheme")) -}}
  {{- $host := default "" (get $parsed "host") -}}
  {{- $path := default "" (get $parsed "path") -}}
  {{- $query := default "" (get $parsed "query") -}}
  {{- $fragment := default "" (get $parsed "fragment") -}}
  {{- $userinfo := default "" (get $parsed "userinfo") -}}
  {{- $hasExplicitPort := regexMatch ":[0-9]+$" $host -}}
  {{- $hasSupportedPort := regexMatch ":443$" $host -}}
  {{- if or (ne $scheme "https") (eq $host "") (and (ne $path "") (ne $path "/")) (ne $query "") (ne $fragment "") (ne $userinfo "") (and $hasExplicitPort (not $hasSupportedPort)) -}}
    {{- fail "webNg.publicUrl must be a bare HTTPS origin on port 443 (for example, https://serviceradar.example.com)" -}}
  {{- end -}}
  {{- trimSuffix "/" $publicUrl -}}
{{- end -}}
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

{{/* Keep target-scoped SSH account/principal policy in an operator-owned Secret. */}}
{{- define "serviceradar.validateRemoteAccessSSHCertificatePolicy" -}}
{{- $remoteAccess := default (dict) .Values.remoteAccess -}}
{{- $policy := default (dict) $remoteAccess.sshCertificatePolicy -}}
{{- $enabled := false -}}
{{- if hasKey $policy "enabled" -}}{{- $enabled = get $policy "enabled" -}}{{- end -}}
{{- if $enabled -}}
  {{- if eq (default "" $policy.existingSecretName) "" -}}
    {{- fail "remoteAccess.sshCertificatePolicy.existingSecretName is required when remoteAccess.sshCertificatePolicy.enabled=true" -}}
  {{- end -}}
  {{- if eq (default "" $policy.secretKey) "" -}}
    {{- fail "remoteAccess.sshCertificatePolicy.secretKey is required when remoteAccess.sshCertificatePolicy.enabled=true" -}}
  {{- end -}}
  {{- $workloads := default (dict) $policy.workloads -}}
  {{- $web := true -}}
  {{- if hasKey $workloads "web" -}}{{- $web = get $workloads "web" -}}{{- end -}}
  {{- $core := false -}}
  {{- if hasKey $workloads "core" -}}{{- $core = get $workloads "core" -}}{{- end -}}
  {{- if not (or $web $core) -}}
    {{- fail "remoteAccess.sshCertificatePolicy must be mounted in at least one workload" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* Keep SSH CA private-key custody explicit and fail closed on incomplete mounts. */}}
{{- define "serviceradar.validateRemoteAccessSSHCaSigner" -}}
{{- $remoteAccess := default (dict) .Values.remoteAccess -}}
{{- $signer := default (dict) $remoteAccess.sshCaSigner -}}
{{- $enabled := false -}}
{{- if hasKey $signer "enabled" -}}{{- $enabled = get $signer "enabled" -}}{{- end -}}
{{- if $enabled -}}
  {{- if eq (default "" $signer.existingSecretName) "" -}}
    {{- fail "remoteAccess.sshCaSigner.existingSecretName is required when remoteAccess.sshCaSigner.enabled=true" -}}
  {{- end -}}
  {{- if eq (default "" $signer.secretKey) "" -}}
    {{- fail "remoteAccess.sshCaSigner.secretKey is required when remoteAccess.sshCaSigner.enabled=true" -}}
  {{- end -}}
  {{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" (default "" $signer.keyId)) -}}
    {{- fail "remoteAccess.sshCaSigner.keyId must be a stable non-secret key identifier" -}}
  {{- end -}}
  {{- if ne (default "/run/secrets/serviceradar_ssh_ca" $signer.mountPath) "/run/secrets/serviceradar_ssh_ca" -}}
    {{- fail "remoteAccess.sshCaSigner.mountPath must remain /run/secrets/serviceradar_ssh_ca" -}}
  {{- end -}}
  {{- if not (kindIs "slice" $signer.args) -}}
    {{- fail "remoteAccess.sshCaSigner.args must be a JSON-array-compatible list" -}}
  {{- end -}}
  {{- $workloads := default (dict) $signer.workloads -}}
  {{- $web := true -}}
  {{- if hasKey $workloads "web" -}}{{- $web = get $workloads "web" -}}{{- end -}}
  {{- $core := false -}}
  {{- if hasKey $workloads "core" -}}{{- $core = get $workloads "core" -}}{{- end -}}
  {{- if not (or $web $core) -}}
    {{- fail "remoteAccess.sshCaSigner must be mounted in at least one workload" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* Keep browser ICE metadata non-secret and TURN REST key custody file-only. */}}
{{- define "serviceradar.validateRemoteAccessDesktopWebRTC" -}}
{{- $remoteAccess := default (dict) .Values.remoteAccess -}}
{{- $desktop := default (dict) $remoteAccess.desktop -}}
{{- $rdp := default (dict) $desktop.rdp -}}
{{- $rdpEnabled := false -}}
{{- if hasKey $rdp "enabled" -}}{{- $rdpEnabled = get $rdp "enabled" -}}{{- end -}}
{{- $webrtc := default (dict) $rdp.webRTC -}}
{{- $iceServers := default (list) $webrtc.iceServers -}}
{{- if and $rdpEnabled (not (kindIs "slice" $iceServers)) -}}
  {{- fail "remoteAccess.desktop.rdp.webRTC.iceServers must be a list" -}}
{{- end -}}
{{- $iceServersJSON := toJson $iceServers -}}
{{- if and $rdpEnabled (regexMatch "(?i)\"(username|credential|turn_shared_secret|shared_secret)\"[[:space:]]*:" $iceServersJSON) -}}
  {{- fail "remoteAccess.desktop.rdp.webRTC.iceServers must not contain credentials or shared secrets" -}}
{{- end -}}
{{- $turnConfigured := and $rdpEnabled (regexMatch "(?i)\"turns?:" $iceServersJSON) -}}
{{- if $turnConfigured -}}
  {{- $turn := default (dict) $webrtc.turn -}}
  {{- if eq (default "" $turn.existingSecretName) "" -}}
    {{- fail "remoteAccess.desktop.rdp.webRTC.turn.existingSecretName is required when TURN endpoints are configured" -}}
  {{- end -}}
  {{- if eq (default "" $turn.secretKey) "" -}}
    {{- fail "remoteAccess.desktop.rdp.webRTC.turn.secretKey is required when TURN endpoints are configured" -}}
  {{- end -}}
  {{- $ttl := int (default 600 $turn.credentialTtlSeconds) -}}
  {{- if or (le $ttl 0) (gt $ttl 3600) -}}
    {{- fail "remoteAccess.desktop.rdp.webRTC.turn.credentialTtlSeconds must be between 1 and 3600" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Convert a Kubernetes storage quantity to whole GiB.

Three CNPG WAL parameters derive from cnpg.storageSize, and pg_wal shares the data
PVC, so a mis-parsed size is a disk-exhaustion bug rather than a cosmetic one. The
pattern this replaces stripped the unit instead of converting it, which rendered a
1Ti volume as "1" and collapsed its WAL cap to the 10GB floor.

A bare number is BYTES in Kubernetes, not GiB -- mapping it to GiB turns
storageSize: 107374182400 into 4294967296 GiB and an effectively unbounded cap,
which is the exact condition the WAL cap guard exists to prevent.

Fails loudly on anything it cannot compute rather than guessing.
*/}}
{{- define "serviceradar.storageGiB" -}}
{{- $raw := trim (toString (default "100Gi" .)) -}}
{{- if contains "." $raw -}}
{{- fail (printf "storage size %q must be a whole number; use e.g. 1536Gi instead of 1.5Ti" $raw) -}}
{{- end -}}
{{- $num := regexReplaceAll "[^0-9]" $raw "" -}}
{{- if eq $num "" -}}
{{- fail (printf "storage size %q has no numeric component" $raw) -}}
{{- end -}}
{{- $n := int64 $num -}}
{{- $unit := regexReplaceAll "[0-9]" $raw "" -}}
{{- $bytes := int64 0 -}}
{{- if eq $unit "Ki" -}}{{- $bytes = mul $n 1024 -}}
{{- else if eq $unit "Mi" -}}{{- $bytes = mul $n 1048576 -}}
{{- else if eq $unit "Gi" -}}{{- $bytes = mul $n 1073741824 -}}
{{- else if eq $unit "Ti" -}}{{- $bytes = mul $n 1099511627776 -}}
{{- else if eq $unit "Pi" -}}{{- $bytes = mul $n 1125899906842624 -}}
{{- else if eq $unit "k" -}}{{- $bytes = mul $n 1000 -}}
{{- else if eq $unit "M" -}}{{- $bytes = mul $n 1000000 -}}
{{- else if eq $unit "G" -}}{{- $bytes = mul $n 1000000000 -}}
{{- else if eq $unit "T" -}}{{- $bytes = mul $n 1000000000000 -}}
{{- else if eq $unit "P" -}}{{- $bytes = mul $n 1000000000000000 -}}
{{- else if eq $unit "" -}}{{- $bytes = $n -}}
{{- else -}}
{{- fail (printf "storage size %q uses unsupported unit %q; use Ki/Mi/Gi/Ti/Pi or k/M/G/T/P" $raw $unit) -}}
{{- end -}}
{{- div $bytes 1073741824 -}}
{{- end -}}

{{/*
WAL sizing budget derived from a storage quantity, emitted as a dict:
  maxSlotWalKeepSize, maxWalSize, minWalSize (PostgreSQL units), maxWalGiB.

pg_wal shares the data PVC, so every value here is bounded relative to the volume.
The 1GB max_wal_size floor is deliberate: it guarantees an install of ~28Gi or less
spends no extra WAL disk at all, keeping PostgreSQL's own default.
*/}}
{{- define "serviceradar.walBudget" -}}
{{- $storeGiB := int64 (include "serviceradar.storageGiB" .) -}}
{{- $cap := div (mul $storeGiB 30) 100 -}}
{{- if lt $cap 10 -}}{{- $cap = int64 10 -}}{{- end -}}
{{- $half := div $storeGiB 2 -}}
{{- if gt $cap $half -}}{{- $cap = $half -}}{{- end -}}
{{- if lt $cap 1 -}}{{- $cap = int64 1 -}}{{- end -}}
{{- $maxWalGiB := div (mul $storeGiB 7) 100 -}}
{{- if lt $maxWalGiB 1 -}}{{- $maxWalGiB = int64 1 -}}{{- end -}}
{{- if gt $maxWalGiB 8 -}}{{- $maxWalGiB = int64 8 -}}{{- end -}}
{{- $minWalMB := div (mul $maxWalGiB 1024) 8 -}}
{{- if lt $minWalMB 256 -}}{{- $minWalMB = int64 256 -}}{{- end -}}
{{- if gt $minWalMB 1024 -}}{{- $minWalMB = int64 1024 -}}{{- end -}}
{{- dict "maxSlotWalKeepSize" (printf "%dGB" $cap) "maxWalSize" (printf "%dGB" $maxWalGiB) "minWalSize" (printf "%dMB" $minWalMB) "maxWalGiB" $maxWalGiB | toJson -}}
{{- end -}}

{{/*
serviceradar.flowCollectorConfigJSON -- the flow-collector.json body shared by
the ordinary ConfigMap (flow-collector.yaml, mounted by the Deployment) and
the hook-scoped bootstrap ConfigMap (flow-collector-bootstrap-configmap.yaml,
mounted by the pre-install/pre-upgrade bootstrap Job). One source of truth so
the two can never drift: the Job must see exactly the config the Deployment
will see, including ready_state_path/rehome_state_path.
*/}}
{{- define "serviceradar.flowCollectorConfigJSON" -}}
{{- $readyPath := .Values.flowCollector.readyPath | default "/var/lib/serviceradar/flow-collector.ready" -}}
{{- $cfg := deepCopy (default (dict) .Values.flowCollector.config) -}}
{{- $rehomePath := index $cfg "rehome_state_path" | default "/var/lib/serviceradar/flow-collector-rehome.json" -}}
{{- $_ := set $cfg "ready_state_path" $readyPath -}}
{{- $_ := set $cfg "rehome_state_path" $rehomePath -}}
{{- toJson $cfg -}}
{{- end -}}
