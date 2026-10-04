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

{{- define "serviceradar.starrocksShadowDatasets" -}}
{{- $sr := default (dict) (default (dict) .Values.analytics).starrocks -}}
{{- $shadow := $sr.shadowDatasets | default list -}}
{{- if eq (len $shadow) 0 -}}
{{- $shadow = list "flows" "metrics" "logs" "events" -}}
{{- end -}}
{{- $shadow | join "," -}}
{{- end -}}

{{/*
A digest of every StarRocks analytics setting, for a pod annotation. It hashes
the values rather than the rendered ConfigMap so a template that is rendered on
its own, as the chart tests do, does not need the ConfigMap template loaded.
The shadow list is included explicitly because it is derived, not set.
*/}}
{{- define "serviceradar.starrocksAnalyticsChecksum" -}}
{{- $sr := default (dict) (default (dict) .Values.analytics).starrocks -}}
{{- printf "%s|%s" (toJson $sr) (include "serviceradar.starrocksShadowDatasets" .) | sha256sum -}}
{{- end -}}

{{- define "serviceradar.starrocksAnalyticsEnv" -}}
{{- $sr := default (dict) (default (dict) .Values.analytics).starrocks -}}
{{- if $sr.enabled }}
- name: SERVICERADAR_STARROCKS_ENABLED
  value: "true"
- name: SERVICERADAR_STARROCKS_CATALOG_ENABLED
  valueFrom:
    configMapKeyRef:
      name: {{ include "serviceradar.fullname" . }}-starrocks-analytics
      key: catalogEnabled
- name: SERVICERADAR_STARROCKS_CUTOVER_DATASETS
  valueFrom:
    configMapKeyRef:
      name: {{ include "serviceradar.fullname" . }}-starrocks-analytics
      key: cutoverDatasets
- name: SERVICERADAR_STARROCKS_SHADOW_DATASETS
  value: {{ include "serviceradar.starrocksShadowDatasets" . | quote }}
- name: SERVICERADAR_STARROCKS_DATABASE
  valueFrom:
    configMapKeyRef:
      name: {{ include "serviceradar.fullname" . }}-starrocks-analytics
      key: database
{{- $retention := default (dict) $sr.retentionDays }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS
  value: {{ $retention.flows | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_METRICS
  value: {{ $retention.metrics | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_LOGS
  value: {{ $retention.logs | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_EVENTS
  value: {{ $retention.events | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_MTR
  value: {{ $retention.mtr | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_OTEL
  value: {{ $retention.otel | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_TRACES
  value: {{ $retention.traces | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_BMP
  value: {{ $retention.bmp | default 365 | quote }}
- name: SERVICERADAR_STARROCKS_RETENTION_DAYS_ATTRIBUTION
  value: {{ $retention.attribution | default 30 | quote }}
{{- /* Not `default`: sprig treats 0 as empty, and 0 is the strictest setting
       this knob accepts (serve only a fully current view), not an absent one. */}}
{{- $rollupStaleAfter := 7200 }}
{{- if not (kindIs "invalid" $sr.rollupStaleAfterSeconds) }}
{{- $rollupStaleAfter = $sr.rollupStaleAfterSeconds }}
{{- end }}
- name: SERVICERADAR_STARROCKS_ROLLUP_STALE_AFTER_SECONDS
  value: {{ $rollupStaleAfter | quote }}
{{- /* Same reason as above: 0 is the strictest setting (never reuse a mark),
       not an absent one. */}}
{{- $rollupCacheTtl := 60 }}
{{- if not (kindIs "invalid" $sr.rollupCacheTtlSeconds) }}
{{- $rollupCacheTtl = $sr.rollupCacheTtlSeconds }}
{{- end }}
- name: SERVICERADAR_STARROCKS_ROLLUP_CACHE_TTL_SECONDS
  value: {{ $rollupCacheTtl | quote }}
{{- /* Stream Load sizing: EventWriter flushes a warehouse batch after maxAgeMs,
       splits it into loads of at most maxRows rows / maxBytes bytes, and runs at
       most maxInFlight of them at once. Read from the analytics ConfigMap so a
       change rolls core through its checksum. */}}
{{- range $key := list "maxRows" "maxBytes" "maxAgeMs" "maxInFlight" }}
- name: SERVICERADAR_STARROCKS_STREAM_LOAD_{{ $key | snakecase | upper }}
  valueFrom:
    configMapKeyRef:
      name: {{ include "serviceradar.fullname" $ }}-starrocks-analytics
      key: streamLoad{{ $key | title }}
{{- end }}
- name: SERVICERADAR_STARROCKS_FE_HTTP
  value: {{ printf "http://%s:%v" $sr.fe.service $sr.fe.httpPort | quote }}
- name: SERVICERADAR_STARROCKS_FE_HOST
  value: {{ $sr.fe.service | quote }}
- name: SERVICERADAR_STARROCKS_FE_QUERY_PORT
  value: {{ $sr.fe.queryPort | quote }}
{{- /* Same Frontend account the provisioning Jobs authenticate as (both run
       `mysql -u root` with this secret), so it has one source of truth. */}}
- name: SERVICERADAR_STARROCKS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "serviceradar.starrocksFePasswordSecretName" . | quote }}
      key: {{ include "serviceradar.starrocksFePasswordSecretKey" . | quote }}
{{- end }}
{{- end -}}

{{/*
The Secret holding the StarRocks Frontend `root` password, in the release
namespace. core, web-ng (EventWriter Stream Load and the MyXQL reader) and both
provisioning Jobs authenticate as that one account.

There is deliberately no way to render StarRocks analytics without it, and no
flag to allow one: the operator chart creates `root` with no password unless
its initPassword is enabled, so an empty value here meant every install path
connected to a Frontend anyone who could reach port 9030 could administer.
The render fails instead of silently falling back to a passwordless login.
*/}}
{{- define "serviceradar.starrocksFePasswordSecretName" -}}
{{- $sr := default (dict) (default (dict) .Values.analytics).starrocks -}}
{{- $cat := default (dict) $sr.catalog -}}
{{- if and $sr.enabled (not $cat.fePasswordSecretName) -}}
{{- fail "analytics.starrocks.catalog.fePasswordSecretName is required when analytics.starrocks.enabled=true: set it to a Secret in the release namespace whose key analytics.starrocks.catalog.fePasswordSecretKey (default \"password\") holds the StarRocks Frontend root password, the same value as the StarRocks operator's initPassword Secret. A passwordless Frontend is not supported; see \"Frontend root password\" in k8s/starrocks/README.md." -}}
{{- end -}}
{{- $cat.fePasswordSecretName -}}
{{- end -}}

{{- define "serviceradar.starrocksFePasswordSecretKey" -}}
{{- $sr := default (dict) (default (dict) .Values.analytics).starrocks -}}
{{- $cat := default (dict) $sr.catalog -}}
{{- $cat.fePasswordSecretKey | default "password" -}}
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
{{- div (int64 (include "serviceradar.quantityBytes" (default "100Gi" .))) 1073741824 -}}
{{- end -}}

{{/*
Convert a Kubernetes storage quantity to bytes (see serviceradar.storageGiB for why
a bare number is bytes and why a fraction fails). Kubernetes units are
case-sensitive: Gi is 2^30 and G is 10^9.
*/}}
{{- define "serviceradar.quantityBytes" -}}
{{- $raw := trim (toString .) -}}
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
{{- $bytes -}}
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
JetStream storage budget (openspec change update-jetstream-storage-budget).

NATS reserves a stream's full max_bytes on every server holding a replica and
refuses to place a stream when no server has that much of max_file_store left
(err 10005). The chart therefore owns every reservation ServiceRadar creates:
it resolves each from its own value or the selected sizing profile
(files/jetstream-profiles.yaml, nats.jetstream.profile), renders it into the
environment of the component that creates the stream, and checks the total at
render time. Moving to a larger profile: docs/nats-jetstream-profile-runbook.md.
*/}}

{{/*
A size in the NATS quantity grammar, as bytes. NATS lower-cases the suffix:
k/m/g/t are powers of 1000 and kb/ki/kib (and the m/g/t equivalents) are powers
of 1024, so 30G is 30000000000 and 30Gi is 32212254720. A bare number is bytes.
Fails on anything NATS would not read as a positive size.
Takes (dict "value" <raw> "what" <value path, for the error>).
*/}}
{{- define "serviceradar.natsSizeBytes" -}}
{{- $v := .value -}}
{{- $raw := "" -}}
{{- if kindIs "float64" $v -}}
{{- if ne (floor $v) $v -}}
{{- fail (printf "%s: %v is not a whole number of bytes" .what $v) -}}
{{- end -}}
{{- $raw = printf "%.0f" $v -}}
{{- else -}}
{{- $raw = trim (toString $v) -}}
{{- end -}}
{{- if not (regexMatch "^[1-9][0-9]*[A-Za-z]*$" $raw) -}}
{{- fail (printf "%s: %q is not a positive size; use a whole number of bytes or a NATS quantity such as 30G (10^9 bytes) or 30Gi (2^30 bytes)" .what $raw) -}}
{{- end -}}
{{- $n := int64 (regexReplaceAll "^([0-9]+)[A-Za-z]*$" $raw "${1}") -}}
{{- $unit := lower (regexReplaceAll "^[0-9]+([A-Za-z]*)$" $raw "${1}") -}}
{{- $mult := dict "" 1 "k" 1000 "kb" 1024 "ki" 1024 "kib" 1024 "m" 1000000 "mb" 1048576 "mi" 1048576 "mib" 1048576 "g" 1000000000 "gb" 1073741824 "gi" 1073741824 "gib" 1073741824 "t" 1000000000000 "tb" 1099511627776 "ti" 1099511627776 "tib" 1099511627776 -}}
{{- if not (hasKey $mult $unit) -}}
{{- fail (printf "%s: %q uses unit %q, which NATS does not read; use k/M/G/T (powers of 1000) or Ki/Mi/Gi/Ti (powers of 1024)" .what $raw $unit) -}}
{{- end -}}
{{- mul $n (index $mult $unit) -}}
{{- end -}}

{{/*
A JetStream replica count: an integer from 1 to 5 (the NATS maximum).
Takes (dict "value" <raw> "what" <value path, for the error>).
*/}}
{{- define "serviceradar.jetstreamReplicaCount" -}}
{{- $raw := trim (toString .value) -}}
{{- if not (regexMatch "^[1-5]$" $raw) -}}
{{- fail (printf "%s: %q is not a JetStream replica count; use an integer from 1 to 5" .what $raw) -}}
{{- end -}}
{{- $raw -}}
{{- end -}}

{{/*
The JetStream replica count the chart renders: min(configured, nats.replicas)
when the chart deploys NATS itself (the same gate as templates/nats.yaml), so a
standalone server never gets a stream with R>1, which nats-server rejects
(JSStreamReplicasNotSupportedErr), and a cluster never gets more replicas than
it has servers. Against an external NATS the configured value is kept: the
chart does not know its size. Every stream replica count the chart renders goes
through here, and so does the budget.
Takes (dict "root" <root context> "value" <raw> "what" <value path, for the error>).
*/}}
{{- define "serviceradar.jetstreamEffectiveReplicas" -}}
{{- $r := int64 (include "serviceradar.jetstreamReplicaCount" (dict "value" .value "what" .what)) -}}
{{- $nats := default (dict) .root.Values.nats -}}
{{- if or (not (hasKey $nats "enabled")) $nats.enabled -}}
{{- $servers := int64 (default 1 $nats.replicas) -}}
{{- if gt $r $servers -}}{{- $r = $servers -}}{{- end -}}
{{- end -}}
{{- $r -}}
{{- end -}}

{{/*
SERVICERADAR_JS_<STREAM>_<SUFFIX>, where <STREAM> is the stream name upper-cased
with every other character replaced by "_" (design D7). This is the name every
size-owning component reads, e.g. SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_MAX_BYTES.
Takes (dict "stream" <stream name> "suffix" <MAX_BYTES|REPLICAS|...>).
*/}}
{{- define "serviceradar.jetstreamEnvName" -}}
{{- printf "SERVICERADAR_JS_%s_%s" (regexReplaceAll "[^A-Z0-9]" (upper .stream) "_") .suffix -}}
{{- end -}}

{{/*
Every JetStream reservation, resolved, plus the render-time budget, as JSON.
Templates read sizes from here, so the value a component is given is the value
the budget counted. A size is the explicit chart value when set, otherwise the
selected profile's; a replica count is the explicit value when set, otherwise
the profile default.

Budget (design D5), with n = nats.replicas:
  full   = streams with replicas >= n (a replica on every server)
  spread = streams with replicas <  n
  need   = sum(max_bytes of full)
         + ceil(sum(max_bytes * replicas of spread) / n)
         + max(max_bytes of spread)
and need must not exceed 85% of max_file_store. flows and ARANCINI_CAUSAL are
counted at the collector's size whether or not the collector is enabled: a
collector that claimed its stream keeps that size after it is disabled. The
EventWriter fallbacks for them are not counted, so they must not exceed it.

max_file_store must also stay within 94% of nats.persistence.size. That check
is about the disk, and nats.jetstream.allowOvercommit does not skip it.
*/}}
{{- define "serviceradar.jetstreamBudget" -}}
{{- $v := .Values -}}
{{- $nats := default (dict) $v.nats -}}
{{- $js := default (dict) $nats.jetstream -}}
{{- $persistence := default (dict) $nats.persistence -}}
{{- $profileName := toString (default "small" $js.profile) -}}
{{- $data := .Files.Get "files/jetstream-profiles.yaml" | fromYaml -}}
{{- $profiles := default (dict) $data.profiles -}}
{{- if not (hasKey $profiles $profileName) -}}
{{- fail (printf "nats.jetstream.profile %q is not a JetStream sizing profile; use one of: %s" $profileName (keys $profiles | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $profile := index $profiles $profileName -}}
{{- $natsReplicas := int64 (default 1 $nats.replicas) -}}
{{- /* A one- or two-server NATS takes the profile's single-server table (the
     Compose sizes): with R3 streams on every server and fewer servers to spread
     the R1 streams over, the three-server table does not fit. */ -}}
{{- $profileSizes := default (dict) $profile.sizes -}}
{{- $sizeTable := "sizes" -}}
{{- if and (lt $natsReplicas 3) $profile.singleServerSizes -}}
{{- $profileSizes = $profile.singleServerSizes -}}
{{- $sizeTable = "singleServerSizes" -}}
{{- end -}}
{{- $profileReplicas := default (dict) $data.replicas -}}
{{- $profileSource := printf "nats.jetstream.profile=%s" $profileName -}}
{{- if eq $sizeTable "singleServerSizes" -}}
{{- $profileSource = printf "nats.jetstream.profile=%s single-server" $profileName -}}
{{- end -}}
{{- $mfsRaw := $profile.maxFileStore -}}
{{- $mfsSource := $profileSource -}}
{{- if and (not (kindIs "invalid" $js.maxFileStore)) (ne (toString $js.maxFileStore) "") -}}
{{- $mfsRaw = $js.maxFileStore -}}
{{- $mfsSource = "nats.jetstream.maxFileStore" -}}
{{- end -}}
{{- $maxFileStore := int64 (include "serviceradar.natsSizeBytes" (dict "value" $mfsRaw "what" $mfsSource)) -}}
{{- $pvcSize := toString (default "30Gi" $persistence.size) -}}
{{- $pvcBytes := int64 (include "serviceradar.quantityBytes" $pvcSize) -}}

{{- $datasvc := default (dict) $v.datasvc -}}
{{- $logCollector := default (dict) $v.logCollector -}}
{{- $flowCfg := default (dict) (default (dict) $v.flowCollector).config -}}
{{- $bmpCfg := default (dict) (default (dict) $v.bmpCollector).config -}}
{{- $webNg := default (dict) $v.webNg -}}
{{- $pluginStorage := default (dict) $webNg.pluginStorage -}}
{{- $fieldSurvey := default (dict) $webNg.fieldSurveyArtifactStore -}}
{{- $core := default (dict) $v.core -}}
{{- $threatIntel := default (dict) $core.threatIntelRawPayloadStore -}}
{{- $ewStreams := default (dict) (default (dict) $core.eventWriter).streams -}}

{{- $entries := list
  (dict "id" "datasvcKV" "stream" "KV_serviceradar-datasvc" "source" "datasvc.bucketMaxBytes" "value" $datasvc.bucketMaxBytes "replicaSource" "datasvc.jetstreamReplicas" "replicaValue" $datasvc.jetstreamReplicas "counted" true)
  (dict "id" "datasvcObjects" "stream" "OBJ_serviceradar-objects" "source" "datasvc.objectStoreBytes" "value" $datasvc.objectStoreBytes "replicaSource" "datasvc.jetstreamReplicas" "replicaValue" $datasvc.jetstreamReplicas "counted" true)
  (dict "id" "events" "stream" "events" "source" "logCollector.streamMaxBytes" "value" $logCollector.streamMaxBytes "replicaSource" "logCollector.streamReplicas" "replicaValue" $logCollector.streamReplicas "counted" true)
  (dict "id" "flows" "stream" (toString (default "flows" $flowCfg.stream_name)) "source" "flowCollector.config.stream_max_bytes" "value" $flowCfg.stream_max_bytes "replicaSource" "flowCollector.config.stream_replicas" "replicaValue" $flowCfg.stream_replicas "counted" true)
  (dict "id" "plugins" "stream" (printf "OBJ_%s" (default "serviceradar_plugins" $pluginStorage.jetstreamBucket)) "source" "webNg.pluginStorage.jetstreamMaxBucketBytes" "value" $pluginStorage.jetstreamMaxBucketBytes "replicaSource" "webNg.pluginStorage.jetstreamReplicas" "replicaValue" $pluginStorage.jetstreamReplicas "counted" true)
  (dict "id" "arancini" "stream" (toString (default "ARANCINI_CAUSAL" $bmpCfg.streamName)) "source" "bmpCollector.config.streamMaxBytes" "value" $bmpCfg.streamMaxBytes "replicaSource" "bmpCollector.config.streamReplicas" "replicaValue" $bmpCfg.streamReplicas "counted" true)
-}}
{{- range $name := list "metrics" "k8s_inventory" "analytics_predictions" "mtr_results" "scan_results" "trivy_reports" -}}
{{- $ewStream := default (dict) (index $ewStreams $name) -}}
{{- $entries = append $entries (dict "id" $name "stream" $name "source" (printf "core.eventWriter.streams.%s.maxBytes" $name) "value" $ewStream.maxBytes "replicaSource" "" "replicaValue" nil "counted" true) -}}
{{- end -}}
{{- $ewFlows := default (dict) (index $ewStreams "flows") -}}
{{- $ewArancini := default (dict) (index $ewStreams "ARANCINI_CAUSAL") -}}
{{- $ewNotifications := default (dict) (index $ewStreams "notifications") -}}
{{- $entries = concat $entries (list
  (dict "id" "notifications" "stream" "NOTIFICATIONS" "source" "core.eventWriter.streams.notifications.maxBytes" "value" $ewNotifications.maxBytes "replicaSource" "" "replicaValue" nil "counted" true)
  (dict "id" "fieldsurvey" "stream" (printf "OBJ_%s" (default "serviceradar_fieldsurvey" $fieldSurvey.jetstreamBucket)) "source" "webNg.fieldSurveyArtifactStore.jetstreamMaxBucketBytes" "value" $fieldSurvey.jetstreamMaxBucketBytes "replicaSource" "" "replicaValue" nil "counted" true)
  (dict "id" "threatIntel" "stream" "OBJ_serviceradar_threat_intel" "source" "core.threatIntelRawPayloadStore.jetstreamMaxBucketBytes" "value" $threatIntel.jetstreamMaxBucketBytes "replicaSource" "" "replicaValue" nil "counted" true)
  (dict "id" "flowsFallback" "stream" "flows" "source" "core.eventWriter.streams.flows.maxBytes" "value" $ewFlows.maxBytes "replicaSource" "core.eventWriter.streams.flows.replicas" "replicaValue" $ewFlows.replicas "counted" false)
  (dict "id" "aranciniFallback" "stream" "ARANCINI_CAUSAL" "source" "core.eventWriter.streams.ARANCINI_CAUSAL.maxBytes" "value" $ewArancini.maxBytes "replicaSource" "core.eventWriter.streams.ARANCINI_CAUSAL.replicas" "replicaValue" $ewArancini.replicas "counted" false)
) -}}

{{- $sizes := dict -}}
{{- $full := int64 0 -}}
{{- $spread := int64 0 -}}
{{- $largest := int64 0 -}}
{{- $lines := list -}}
{{- range $e := $entries -}}
{{- $src := $profileSource -}}
{{- $raw := index $profileSizes $e.id -}}
{{- if and $e.source (not (kindIs "invalid" $e.value)) (ne (toString $e.value) "") -}}
{{- $raw = $e.value -}}
{{- $src = $e.source -}}
{{- end -}}
{{- $mb := int64 (include "serviceradar.natsSizeBytes" (dict "value" $raw "what" $src)) -}}
{{- $rraw := index $profileReplicas $e.id -}}
{{- $rsrc := "files/jetstream-profiles.yaml replicas" -}}
{{- if and $e.replicaSource (not (kindIs "invalid" $e.replicaValue)) (ne (toString $e.replicaValue) "") -}}
{{- $rraw = $e.replicaValue -}}
{{- $rsrc = $e.replicaSource -}}
{{- end -}}
{{- $configuredR := int64 (include "serviceradar.jetstreamReplicaCount" (dict "value" $rraw "what" $rsrc)) -}}
{{- $r := int64 (include "serviceradar.jetstreamEffectiveReplicas" (dict "root" $ "value" $rraw "what" $rsrc)) -}}
{{- $capNote := "" -}}
{{- if ne $r $configuredR -}}
{{- $capNote = printf " (capped from R%d by nats.replicas)" $configuredR -}}
{{- end -}}
{{- $bucket := "not counted" -}}
{{- if $e.counted -}}
{{- if ge $r $natsReplicas -}}
{{- $full = add $full $mb -}}
{{- $bucket = "full" -}}
{{- else -}}
{{- $spread = add $spread (mul $mb $r) -}}
{{- if gt $mb $largest -}}{{- $largest = $mb -}}{{- end -}}
{{- $bucket = "spread" -}}
{{- end -}}
{{- $lines = append $lines (printf "%s: %d bytes (%.2f GiB) x R%d%s, %s [%s]" $e.stream $mb (divf $mb 1073741824) $r $capNote $bucket $src) -}}
{{- end -}}
{{- $_ := set $sizes $e.id (dict "stream" $e.stream "maxBytes" (printf "%d" $mb) "replicas" (printf "%d" $r) "source" $src "bucket" $bucket) -}}
{{- end -}}

{{- $spreadShare := div (add $spread (sub $natsReplicas 1)) $natsReplicas -}}
{{- $need := add $full $spreadShare $largest -}}
{{- $limit := div (mul $maxFileStore 85) 100 -}}
{{- $problems := list -}}
{{- if gt (mul $need 100) (mul $maxFileStore 85) -}}
{{- $problems = append $problems (printf "the most loaded NATS server may have to reserve %d bytes (%.2f GiB), above the limit of %d bytes (%.2f GiB): 85%% of max_file_store %d bytes (%.2f GiB, from %s) with nats.replicas=%d; need = full + ceil(sum(max_bytes x replicas of spread) / nats.replicas) + largest spread max_bytes = %d + %d + %d bytes (a stream with replicas >= nats.replicas reserves its max_bytes on every server and is full; the others are spread)." $need (divf $need 1073741824) $limit (divf $limit 1073741824) $maxFileStore (divf $maxFileStore 1073741824) $mfsSource $natsReplicas $full $spreadShare $largest) -}}
{{- end -}}
{{- range $pair := list (list "flowsFallback" "flows") (list "aranciniFallback" "arancini") -}}
{{- $fallback := index $sizes (index $pair 0) -}}
{{- $owner := index $sizes (index $pair 1) -}}
{{- if gt (int64 $fallback.maxBytes) (int64 $owner.maxBytes) -}}
{{- $problems = append $problems (printf "the EventWriter fallback for %s (%s bytes from %s) exceeds the collector size the budget counts (%s bytes from %s); lower the fallback or raise the collector size." $fallback.stream $fallback.maxBytes $fallback.source $owner.maxBytes $owner.source) -}}
{{- end -}}
{{- end -}}
{{- $budgetMessage := "" -}}
{{- if $problems -}}
{{- $budgetMessage = printf "JetStream storage budget exceeded (nats.jetstream.profile=%s): %s Reservations (max_bytes x replicas, bucket, source): %s. Lower a size, move to a larger sizing profile (docs/nats-jetstream-profile-runbook.md), or set nats.jetstream.allowOvercommit=true to accept that a new stream may not be placeable." $profileName (join " Also, " $problems) (join "; " $lines) -}}
{{- end -}}
{{- $diskMessage := "" -}}
{{- if gt (mul $maxFileStore 100) (mul $pvcBytes 94) -}}
{{- $diskMessage = printf "NATS max_file_store %d bytes (%.2f GiB, from %s) exceeds 94%% of nats.persistence.size %s (%d bytes), so NATS could promise more space than the volume holds. The StatefulSet volumeClaimTemplates are immutable: moving to a larger profile means expanding every serviceradar-nats PVC first and then raising nats.persistence.size, as docs/nats-jetstream-profile-runbook.md describes. nats.jetstream.allowOvercommit does not skip this check." $maxFileStore (divf $maxFileStore 1073741824) $mfsSource $pvcSize $pvcBytes -}}
{{- end -}}
{{- dict "profile" $profileName "sizeTable" $sizeTable "maxFileStore" (printf "%d" $maxFileStore) "natsReplicas" (printf "%d" $natsReplicas) "need" (printf "%d" $need) "limit" (printf "%d" $limit) "sizes" $sizes "budgetMessage" $budgetMessage "diskMessage" $diskMessage | toJson -}}
{{- end -}}

{{/*
Render-time guard, called from templates/nats.yaml: always fails on the disk
ceiling, and fails on the reservation budget unless
nats.jetstream.allowOvercommit is true.
Takes (list <root context> <budget dict from serviceradar.jetstreamBudget>).
*/}}
{{- define "serviceradar.validateJetStreamBudget" -}}
{{- $root := index . 0 -}}
{{- $budget := index . 1 -}}
{{- $js := default (dict) (default (dict) $root.Values.nats).jetstream -}}
{{- if $budget.diskMessage -}}
{{- fail $budget.diskMessage -}}
{{- end -}}
{{- if and $budget.budgetMessage (not $js.allowOvercommit) -}}
{{- fail $budget.budgetMessage -}}
{{- end -}}
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
{{- /* The flows reservation is the one the JetStream budget counted: the explicit
     config value when set, otherwise the sizing profile's. */ -}}
{{- $flows := (include "serviceradar.jetstreamBudget" . | fromJson).sizes.flows -}}
{{- $_ := set $cfg "stream_max_bytes" (int64 $flows.maxBytes) -}}
{{- $_ := set $cfg "stream_replicas" (int64 $flows.replicas) -}}
{{- toJson $cfg -}}
{{- end -}}

{{/*
Dgraph subchart fullname. Must stay in lockstep with the official chart's
`dgraph.fullname` (trunc 24): Release.Name-dgraph.
*/}}
{{- define "serviceradar.dgraph.fullname" -}}
{{- printf "%s-dgraph" .Release.Name | trunc 24 | trimSuffix "-" -}}
{{- end -}}

{{- define "serviceradar.dgraph.alphaFullname" -}}
{{- printf "%s-alpha" (include "serviceradar.dgraph.fullname" .) -}}
{{- end -}}

{{- define "serviceradar.dgraph.zeroFullname" -}}
{{- printf "%s-zero" (include "serviceradar.dgraph.fullname" .) -}}
{{- end -}}

{{- define "serviceradar.dgraph.aclSecretName" -}}
{{- printf "%s-acl-secret" (include "serviceradar.dgraph.alphaFullname" .) -}}
{{- end -}}

{{- define "serviceradar.dgraph.alphaTLSSecretName" -}}
{{- printf "%s-tls-secret" (include "serviceradar.dgraph.alphaFullname" .) -}}
{{- end -}}

{{- define "serviceradar.dgraph.zeroTLSSecretName" -}}
{{- printf "%s-tls-secret" (include "serviceradar.dgraph.zeroFullname" .) -}}
{{- end -}}

{{/*
Hostname a client dials. In-chart Service when enabled, else external.host.
Empty when neither is configured: disabling an optional subsystem must not
fail the render of every Deployment that happens to include graph.env.
*/}}
{{- define "serviceradar.dgraph.host" -}}
{{- $d := default (dict) .Values.dgraph -}}
{{- if $d.enabled -}}
{{- printf "%s.%s.svc.cluster.local" (include "serviceradar.dgraph.alphaFullname" .) .Release.Namespace -}}
{{- else -}}
{{- default "" (default (dict) $d.external).host -}}
{{- end -}}
{{- end -}}

{{/*
Non-empty when some Dgraph is reachable: the in-chart cluster, or a configured
external host. Empty means the operator opted out of Dgraph entirely.
*/}}
{{- define "serviceradar.dgraph.configured" -}}
{{- if ne (include "serviceradar.dgraph.host" .) "" -}}
true
{{- end -}}
{{- end -}}

{{- define "serviceradar.dgraph.port" -}}
{{- $d := default (dict) .Values.dgraph -}}
{{- $ext := default (dict) $d.external -}}
{{- default 9080 $ext.port -}}
{{- end -}}

{{/*
TLS mode for application Dgraph clients. In-chart Alpha always serves TLS;
external clusters follow dgraph.external.tlsMode. Application pods use
`require` rather than `verify-ca` so they do not need a CA volume (the schema
Job still verifies).
*/}}
{{- define "serviceradar.dgraph.appTlsMode" -}}
{{- $d := default (dict) .Values.dgraph -}}
{{- if $d.enabled -}}
require
{{- else -}}
{{- $ext := default (dict) $d.external -}}
{{- default "disable" $ext.tlsMode -}}
{{- end -}}
{{- end -}}

{{/*
Userinfo for an external Dgraph. The chart does not provision that cluster, so
the credential comes from a Secret the operator already has
(dgraph.external.credentialsSecret). No secret means no userinfo, which is an
external cluster with ACL disabled. A credential is never a values literal:
graph.env renders into a Deployment spec anyone with `get deploy` can read.
*/}}
{{- define "serviceradar.dgraph.externalUserinfo" -}}
{{- $ext := default (dict) (default (dict) .Values.dgraph).external -}}
{{- if ne (default "" $ext.credentialsSecret) "" -}}
{{- printf "%s:$(DGRAPH_PASSWORD)@" (default "groot" $ext.username) -}}
{{- end -}}
{{- end -}}

{{/*
CA the application pods verify an external Dgraph against, when they verify at
all. The in-chart branch dials `require` and needs none. An external cluster on
`verify-ca` with no caSecret is verifying against the system trust store, which
is correct for a publicly issued certificate and needs no volume either.
*/}}
{{- define "serviceradar.dgraph.appCaSecret" -}}
{{- $d := default (dict) .Values.dgraph -}}
{{- $ext := default (dict) $d.external -}}
{{- if and (not $d.enabled) (eq (include "serviceradar.dgraph.appTlsMode" .) "verify-ca") -}}
{{- default "" $ext.caSecret -}}
{{- end -}}
{{- end -}}

{{- define "serviceradar.dgraph.caVolumeMount" -}}
{{- if ne (include "serviceradar.dgraph.appCaSecret" .) "" }}
- name: dgraph-ca
  mountPath: /etc/dgraph-ca
  readOnly: true
{{- end }}
{{- end -}}

{{- define "serviceradar.dgraph.caVolume" -}}
{{- $ext := default (dict) (default (dict) .Values.dgraph).external -}}
{{- if ne (include "serviceradar.dgraph.appCaSecret" .) "" }}
- name: dgraph-ca
  secret:
    secretName: {{ include "serviceradar.dgraph.appCaSecret" . | quote }}
    items:
    - key: {{ default "ca.crt" $ext.caKey | quote }}
      path: ca.crt
{{- end }}
{{- end -}}

{{/*
`sslrootcert` for the rendered DGRAPH_URL. Without it a `verify-ca` dial checks
the system trust store, which a private cert-manager CA is not in, so every
connection fails the handshake.
*/}}
{{- define "serviceradar.dgraph.appSslRootCert" -}}
{{- if ne (include "serviceradar.dgraph.appCaSecret" .) "" -}}
&sslrootcert=/etc/dgraph-ca/ca.crt
{{- end -}}
{{- end -}}

{{/*
GRAPH_BACKEND / GRAPH_READ / DGRAPH_* for topology writers (core, web-ng).
With no Dgraph configured this stays on AGE and emits no DGRAPH_* at all.
The in-chart cluster's groot password is the generated ACL Secret, never a
literal: kubelet expands $(DGRAPH_PASSWORD) from the preceding entry.
*/}}
{{- define "serviceradar.graph.env" -}}
{{- $graph := default (dict) .Values.graph -}}
{{- $d := default (dict) .Values.dgraph -}}
{{- if not (include "serviceradar.dgraph.configured" .) }}
- name: GRAPH_BACKEND
  value: "age"
- name: GRAPH_READ
  value: "age"
{{- else }}
{{- /*
Dual-write is the default only for the cluster this chart provisions, where it
also mints the ACL credential and applies the topology schema. An external
endpoint is neither, so writing to it has to be an explicit opt-in through
graph.backend rather than a side effect of naming a host.
*/}}
- name: GRAPH_BACKEND
  value: {{ default (ternary "dual" "age" (not (not $d.enabled))) $graph.backend | quote }}
- name: GRAPH_READ
  value: {{ default "age" $graph.read | quote }}
- name: DGRAPH_HOST
  value: {{ include "serviceradar.dgraph.host" . | quote }}
- name: DGRAPH_PORT
  value: {{ include "serviceradar.dgraph.port" . | quote }}
- name: DGRAPH_TLS_MODE
  value: {{ include "serviceradar.dgraph.appTlsMode" . | quote }}
{{- if $d.enabled }}
- name: DGRAPH_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "serviceradar.dgraph.aclSecretName" . | quote }}
      key: groot_password
- name: DGRAPH_URL
  value: {{ printf "dgraph://groot:$(DGRAPH_PASSWORD)@%s:%s?sslmode=%s" (include "serviceradar.dgraph.host" .) (include "serviceradar.dgraph.port" .) (include "serviceradar.dgraph.appTlsMode" .) | quote }}
{{- else }}
{{- $ext := default (dict) $d.external }}
{{- if ne (default "" $ext.credentialsSecret) "" }}
- name: DGRAPH_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $ext.credentialsSecret | quote }}
      key: {{ default "password" $ext.credentialsKey | quote }}
{{- end }}
- name: DGRAPH_URL
  value: {{ printf "dgraph://%s%s:%s?sslmode=%s%s" (include "serviceradar.dgraph.externalUserinfo" .) (include "serviceradar.dgraph.host" .) (include "serviceradar.dgraph.port" .) (include "serviceradar.dgraph.appTlsMode" .) (include "serviceradar.dgraph.appSslRootCert" .) | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Secret holding the StarRocks JDBC catalog reader's username and password. One
name, because three templates have to agree on it: the secret generator mints
it, CNPG managed.roles sets the role's password from it, and the catalog Job
puts that same password into CREATE EXTERNAL CATALOG.
*/}}
{{- define "serviceradar.starrocks.readerSecretName" -}}
{{- $cat := default (dict) (default (dict) (default (dict) .Values.analytics).starrocks).catalog -}}
{{- default "serviceradar-starrocks-reader" $cat.readerPasswordSecret -}}
{{- end -}}

{{/*
serviceradar.boolDefaultTrue renders "true" or "false" for (list $dict "key").
An absent key, a nil or empty value, or a container that is not a map all mean
true; an explicit false (the boolean or the string "false") renders "false".
Use it instead of `default true $x.key`: Sprig's `default` treats false as
empty, so that form turns an explicit `false` back into true.
*/}}
{{- define "serviceradar.boolDefaultTrue" -}}
{{- $d := index . 0 -}}
{{- $k := index . 1 -}}
{{- $v := "" -}}
{{- if and (kindIs "map" $d) (hasKey $d $k) -}}{{- $v = index $d $k -}}{{- end -}}
{{- if or (kindIs "invalid" $v) (eq (toString $v) "") -}}true
{{- else if eq (lower (toString $v)) "false" -}}false
{{- else if $v -}}true
{{- else -}}false
{{- end -}}
{{- end -}}

{{/*
Extra SANs for the NATS runtime certificate so edge-site leaf servers can verify
the leafnode listener by its public name. Renders a leading-comma list
(",DNS:a,DNS:b") or nothing.
*/}}
{{- define "serviceradar.natsLeafCertSans" -}}
{{- $hosted := default (dict) .Values.hostedRuntime -}}
{{- $endpoints := default (dict) $hosted.publicEndpoints -}}
{{- $leafnodes := default (dict) (default (dict) .Values.nats).leafnodes -}}
{{- $leafTls := default (dict) $leafnodes.tls -}}
{{- $names := list -}}
{{- with $endpoints.natsLeafHost }}{{ $names = append $names . }}{{ end -}}
{{- range (default (list) $leafTls.extraDnsNames) }}{{ $names = append $names . }}{{ end -}}
{{- range (uniq $names) }},DNS:{{ . }}{{ end -}}
{{- end -}}

{{/*
Effective upstream URL edge-site leaf servers dial, derived from the hosted
public endpoint facts. Empty when hostedRuntime.publicEndpoints.natsLeafHost is
unset, so web-ng keeps its configured default.
*/}}
{{- define "serviceradar.natsLeafUpstreamUrl" -}}
{{- $hosted := default (dict) .Values.hostedRuntime -}}
{{- $endpoints := default (dict) $hosted.publicEndpoints -}}
{{- with $endpoints.natsLeafHost -}}
tls://{{ . }}:{{ default 7422 $endpoints.natsLeafPort }}
{{- end -}}
{{- end -}}
