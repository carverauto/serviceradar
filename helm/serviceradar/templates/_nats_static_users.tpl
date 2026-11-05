{{- /*
serviceradar.natsStaticUsers is the one definition of every built-in NATS client
identity and its permissions. It renders a YAML list; each entry names the
certificate subject the broker maps (`user`) and its `publish` and `subscribe`
blocks with `allow` and optional `deny` lists, using static NATS semantics: an
empty allow list permits every subject before deny applies.

Two consumers read it, so they cannot drift apart:

  * templates/nats.yaml renders these users into the broker's static
    configuration (verify_and_map).
  * the `serviceradar-nats-static-users` ConfigMap carries the same list to
    core. With certificate authorization enabled the broker sends every one of
    these identities to core's authorization callout, and core grants an
    adopted infrastructure certificate that presents one of these subjects
    exactly this block (ServiceRadar.NATS.StaticIdentityGrants). A stored grant
    copied at adoption time therefore never goes stale when a release adds a
    subject here.

Add or change a built-in identity's subjects only here.
*/ -}}
{{- define "serviceradar.natsStaticUsers" -}}
{{- $kvBucket := default "serviceradar-datasvc" .Values.kv.bucket -}}
{{- $datasvc := default (dict) .Values.datasvc -}}
{{- $objectBucket := default "serviceradar-objects" $datasvc.objectBucket -}}
{{- $webNg := default (dict) .Values.webNg -}}
{{- $webNgPluginStorage := default (dict) $webNg.pluginStorage -}}
{{- $pluginBucket := default "serviceradar_plugins" $webNgPluginStorage.jetstreamBucket -}}
{{- $fieldSurveyStore := default (dict) $webNg.fieldSurveyArtifactStore -}}
{{- $fieldSurveyBucket := default "serviceradar_fieldsurvey" $fieldSurveyStore.jetstreamBucket -}}
{{- $k8sInventory := default (dict) .Values.k8sInventory -}}
{{- $k8sInventoryNats := default (dict) $k8sInventory.nats -}}
{{- $k8sInventoryNodes := default (dict) $k8sInventory.nodes -}}
{{- $k8sInventoryNatsEnabled := and (default false $k8sInventory.enabled) (eq (default "nats" $k8sInventory.publishMode) "nats") -}}
{{- $k8sInventoryNodesEnabled := or (not (hasKey $k8sInventoryNodes "enabled")) $k8sInventoryNodes.enabled -}}
{{- $k8sInventorySubject := default "inventory.k8s.public_endpoints" $k8sInventoryNats.subject -}}
{{- $k8sInventoryStream := default "k8s_inventory" $k8sInventoryNats.stream -}}
{{- $flowCollector := default (dict) .Values.flowCollector -}}
{{- $flowCollectorConfig := default (dict) $flowCollector.config -}}
{{- $flowCollectorEnabled := default false $flowCollector.enabled -}}
{{- $flowCollectorStream := default "flows" $flowCollectorConfig.stream_name -}}
{{- /* B-5 sub-issue 2: partition_id scopes the agent's config subjects. The
     top-level `.Values.partitionId` is the source of truth; agent.partitionId
     is honored as a fallback for releases that only set it under .agent. It
     MUST match SERVICERADAR_OTX_PARTITION on the core-elx runtime config. */ -}}
{{- $partitionId := coalesce .Values.partitionId (default (dict) .Values.agent).partitionId "default" }}
- user: "CN=serviceradar-tools,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: [">"]
  subscribe:
    allow: [">"]
{{- /* Web-NG owns browser/API-facing object-store workflows such as plugin
     WASM/dashboard package imports and FieldSurvey artifacts, and it publishes
     the internal logs, OCSF events, and analytics signals that core code in
     this release emits. It does not publish the notifications.* firehose. Do
     not reuse the core identity for this user. */}}
- user: "CN=serviceradar-web-ng,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow:
      - "$O.{{ $pluginBucket }}.>"
      - "$JS.FC.OBJ_{{ $pluginBucket }}.>"
      - "$O.{{ $fieldSurveyBucket }}.>"
      - "$JS.FC.OBJ_{{ $fieldSurveyBucket }}.>"
      {{- /* Internal audit/onboarding logs, OCSF events and analytics signals
           that core code running inside the web-ng release publishes
           (AuditWriter from UI actions, inventory events,
           ObanFailureEventReporter, SignalPublisher). Without these the broker
           rejects the publish with a Permissions Violation and
           DurablePublishWorker retries it. */}}
      - "logs.internal.>"
      - "events.internal.>"
      - "signals.analytics.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>"]
  subscribe:
    allow:
      - "$O.{{ $pluginBucket }}.>"
      - "$O.{{ $fieldSurveyBucket }}.>"
      {{- /* Notification firehose (design D10): web-ng consumes it with a
           durable cursor so a reconnecting subscriber replays what it missed.
           Subscribe only - web-ng is not a firehose publisher. */}}
      - "notifications.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>"]
{{- /* Core platform service: manages JetStream streams/consumers, publishes
     normalized platform subjects, and uses request/reply inboxes. Flow
     attribution observations go out on flows.attribution.observations;
     nothing reads back through flow.attributed.*. */}}
- user: "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow:
      - "flow.raw.>"
      - "flows.raw.>"
      - "flows.*.processed"
      - "logs.>"
      {{- /* Live tail copies of logs.internal.* (health/audit/jobs). web-ng is
           subscribe-only; core is the publisher. */}}
      - "live.logs.>"
      - "pdns.ocsf"
      - "pdns.ocsf.>"
      - "signals.analytics.>"
      - "events.>"
      - "config.>"
      {{- /* Notification firehose (design D10). Core is the only publisher;
           web-ng subscribes. New subject namespaces are denied by default, so
           omitting this does not surface as an error - every notification on
           the firehose is simply dropped. */}}
      - "notifications.>"
      {{- /* Ad-hoc scan results (AdhocScanResultHandler). Core republishes each
           row here and EventWriter persists it from the scan_results stream.
           Without this entry the plain publish is denied by the server and
           every result is dropped with no error on the publisher side. */}}
      - "scans.results.>"
      {{- /* MTR trace results (MtrResultPublisher). Core publishes; EventWriter
           persists them from the mtr_results stream. The publish waits for a
           PubAck, so a missing entry here fails loudly rather than dropping
           traces. */}}
      - "mtr.results.>"
      {{- /* Flow process attribution observations
           (FlowAttribution.Observations). Core publishes them on the flows
           stream; EventWriter loads them into the warehouse. The publish waits
           for a PubAck, so a missing entry fails the admitted batch instead of
           dropping it. */}}
      - "flows.attribution.observations"
      {{- /* Flow attribution correlator health (FlowAttribution.PassMetrics), a
           metric envelope that EventWriter persists from the metrics stream. */}}
      - "metrics.flow_attribution"
      {{- /* Bounded ingestion lane envelopes from core. EventWriter owns
           persistence from the METRICS stream. */}}
      - "metrics.ingestion_lanes"
      {{- /* Warehouse load-failure counters (Analytics.StarRocks.LoadHealth).
           The publish waits for a PubAck, so a missing entry denies every
           sample and the broker logs a permissions violation. */}}
      - "metrics.event_writer.warehouse"
      {{- /* Agent metric batches republished from edge records
           (MetricsBatchProjection) onto the same subjects the gateway uses,
           metrics.<family>.<metric type>.<metric name>; a sweep summary is
           therefore metrics.sweep.sweep.<name>. The publish waits for a
           PubAck, so a missing entry redelivers the edge-record batch forever.
           One entry per family the projector accepts; a family that has not
           moved stays off this identity. */}}
      - "metrics.sysmon.>"
      - "metrics.snmp.>"
      - "metrics.icmp.>"
      - "metrics.rperf.>"
      - "metrics.mtr.>"
      - "metrics.sweep.>"
      {{- /* Plugin and add-on metric records republished from telemetry batch
           edge records (Projectors.TelemetryBatch) onto the subject the
           gateway's plugin metrics publisher uses. The publish waits for a
           PubAck, so a missing entry redelivers the telemetry batch forever. */}}
      - "metrics.timeseries.>"
      {{- /* OTLP relay chunks republished from edge records
           (Edge.Projectors.OtlpRelay) onto the canonical OTLP subjects.
           logs.otel is already covered by logs.> above. */}}
      - "otel.traces.raw"
      - "otel.metrics.raw"
      - "otel.metrics.derived"
      {{- /* Exposure transitions and CVE/package dimensions, relayed from their
           outboxes into EXPOSURE_TRANSITIONS and EXPOSURE_DIMENSIONS, plus each
           relay's health metrics. Outbox publishes wait for a PubAck, so a
           missing entry leaves that outbox row and fires its age alert. */}}
      - "vulnerability.assessment.transitions.>"
      - "exposure.dimensions.cve"
      - "exposure.dimensions.package"
      {{- /* EXPOSURE_RECOVERY carries unfinished delivery copies and snapshot
           envelopes. Core publishes both. The deny below withholds purge and
           stream deletion; individual message deletion stays on the JetStream
           API allow. */}}
      - "exposure.delivery.recovery.>"
      - "exposure.snapshots.>"
      - "metrics.exposure_transitions"
      - "metrics.exposure_dimensions"
      {{- /* EventWriter's edge-record dead-letter (EdgeRecordDeadLetter) copies
           a record whose projection kept failing here and ACKs the source only
           after the PubAck, so a missing entry leaves the record retrying.
           Replay republishes it to the edge-record subject it came from. The
           deny below withholds purge and deletion of the dead-letter stream;
           deleting one replayed message stays on the JetStream API allow. */}}
      - "telemetry.edge-record-dlq.v1.bulk.>"
      - "telemetry.edge-record.v1.bulk.>"
      - "telemetry.edge-record-audit.v1.bulk.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny:
      - "$SYS.>"
      - "$JS.API.STREAM.PURGE.EXPOSURE_RECOVERY"
      - "$JS.API.STREAM.DELETE.EXPOSURE_RECOVERY"
      - "$JS.API.STREAM.PURGE.TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
      - "$JS.API.STREAM.DELETE.TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
  subscribe:
    allow:
      - "flow.raw.>"
      - "flows.raw.>"
      - "flows.*.processed"
      - "logs.>"
      - "metrics.>"
      - "pdns.ocsf"
      - "pdns.ocsf.>"
      - "signals.analytics.>"
      - "events.>"
      - "config.>"
      - "inventory.k8s.>"
      - "trivy.report.>"
      - "vulnerability.assessment.transitions.>"
      - "exposure.dimensions.cve"
      - "exposure.dimensions.package"
      - "falco.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>"]
{{- /* Agent gateway is the authenticated edge ingress for agent gRPC
     telemetry: durable edge records (primary, audit and security-quarantine
     routes; the pipeline is always on, so these are unconditional), sysmon/SNMP
     status metrics and relayed OTLP chunks. It is not a
     general NATS producer and cannot publish flow attribution, trap/syslog
     logs, or events. metrics.agent_gateway carries the gateway's own core-call
     latency and status-buffer depth (RuntimeMetrics). It waits for a PubAck,
     so without this entry every sample is denied and times out. */}}
- user: "CN=serviceradar-agent-gateway,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow:
      - "telemetry.edge-record.v1.bulk.>"
      - "telemetry.edge-record-audit.v1.bulk.>"
      - "telemetry.edge-record-security-quarantine.v1.bulk.>"
      - "metrics.sysmon.>"
      - "metrics.snmp.>"
      - "metrics.icmp.>"
      - "metrics.mtr.>"
      - "metrics.rperf.>"
      - "metrics.sweep.>"
      - "metrics.timeseries.>"
      - "metrics.agent_gateway"
      - "otel.traces.raw"
      - "otel.metrics.raw"
      - "otel.metrics.derived"
      - "logs.otel"
      - "$JS.API.>"
    deny: ["$SYS.>", "flow.attributed.>", "events.>", "logs.syslog", "logs.syslog.>", "logs.snmp", "logs.snmp.>"]
  subscribe:
    allow: []
    deny: ["$SYS.>", "flow.attributed.>", "flow.host-slice.>"]
{{- /* Datasvc query-side service: reads catalog events/config and object/KV
     state. Attributed flows are queried from CNPG, not a flow.attributed.* NATS
     read-back stream. */}}
- user: "CN=serviceradar-datasvc,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow:
      - "events.>"
      - "config.>"
      - "$KV.{{ $kvBucket }}.>"
      - "$O.{{ $objectBucket }}.>"
      - "$JS.FC.OBJ_{{ $objectBucket }}.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>"]
  subscribe:
    allow:
      - "events.>"
      - "config.>"
      - "$KV.{{ $kvBucket }}.>"
      - "$O.{{ $objectBucket }}.>"
      - "$JS.FC.OBJ_{{ $objectBucket }}.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>"]
{{- /* Agent (B-5 subject-scoping): emits sweep/discovery events and consumes
     config for its partition. Denied from flow.attributed.> (attribution is
     core's responsibility) and $SYS.>. */}}
- user: "CN=serviceradar-agent,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow:
      - "events.>"
      - "logs.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>", "flow.attributed.>"]
  subscribe:
    allow:
      - "config.agent.>"
      - "config.{{ $partitionId }}.>"
      - "$JS.API.>"
      - "$JS.ACK.>"
      - "_INBOX.>"
    deny: ["$SYS.>", "flow.attributed.>", "flow.host-slice.>"]
- user: "CN=serviceradar-log-collector,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["logs.syslog", "otel.>", "logs.otel", "$JS.API.STREAM.INFO.events", "$JS.API.STREAM.CREATE.events", "$JS.API.>"]
  subscribe:
    allow: ["$JS.API.>", "_INBOX.>"]
- user: "CN=serviceradar-flowgger,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["logs.syslog", "$JS.API.STREAM.INFO.events", "$JS.API.STREAM.CREATE.events", "$JS.API.>"]
  subscribe:
    allow: ["$JS.API.>", "_INBOX.>"]
- user: "CN=serviceradar-otel,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["otel.>", "logs.otel", "$JS.API.>"]
  subscribe:
    allow: ["$JS.API.>", "_INBOX.>"]
- user: "CN=serviceradar-trapd,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["logs.snmp", "$JS.API.STREAM.INFO.events", "$JS.API.STREAM.CREATE.events", "$JS.API.>"]
  subscribe:
    allow: ["$JS.API.>", "_INBOX.>"]
- user: "CN=serviceradar-flow-collector,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    {{- if $flowCollectorEnabled }}
    allow: ["flows.raw.>", "flow.host-slice.>", "$JS.API.STREAM.INFO.{{ $flowCollectorStream }}", "$JS.API.STREAM.CREATE.{{ $flowCollectorStream }}", "$JS.API.STREAM.UPDATE.{{ $flowCollectorStream }}", "$JS.API.STREAM.INFO.events", "$JS.API.STREAM.UPDATE.events"]
    {{- else }}
    allow: []
    {{- end }}
  subscribe:
    {{- if $flowCollectorEnabled }}
    allow: ["_INBOX.>"]
    {{- else }}
    allow: []
    {{- end }}
- user: "CN=serviceradar-netflow-collector,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    {{- if $flowCollectorEnabled }}
    allow: ["flows.raw.>", "$JS.API.STREAM.INFO.{{ $flowCollectorStream }}", "$JS.API.STREAM.CREATE.{{ $flowCollectorStream }}", "$JS.API.STREAM.UPDATE.{{ $flowCollectorStream }}", "$JS.API.STREAM.INFO.events", "$JS.API.STREAM.UPDATE.events"]
    {{- else }}
    allow: []
    {{- end }}
  subscribe:
    {{- if $flowCollectorEnabled }}
    allow: ["_INBOX.>"]
    {{- else }}
    allow: []
    {{- end }}
- user: "CN=serviceradar-bmp-collector,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["arancini.updates", "arancini.updates.>", "$JS.API.STREAM.INFO.ARANCINI_CAUSAL", "$JS.API.STREAM.CREATE.ARANCINI_CAUSAL", "$JS.API.>"]
  subscribe:
    allow: ["$JS.API.>", "_INBOX.>"]
- user: "CN=serviceradar-falcosidekick,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["falco.>", "$JS.API.STREAM.INFO.falco_events", "$JS.API.STREAM.CREATE.falco_events", "$JS.API.>"]
  subscribe:
    allow: ["$JS.API.>", "_INBOX.>"]
- user: "CN=serviceradar-trivy-sidecar,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    allow: ["trivy.report.>", "$JS.API.STREAM.INFO.trivy_reports", "$JS.API.STREAM.CREATE.trivy_reports", "$JS.API.STREAM.UPDATE.trivy_reports"]
  subscribe:
    allow: ["_INBOX.>"]
- user: "CN=serviceradar-k8s-inventory,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
  publish:
    {{- if $k8sInventoryNatsEnabled }}
    allow:
      - {{ $k8sInventorySubject | quote }}
      {{- if $k8sInventoryNodesEnabled }}
      - "inventory.k8s.nodes"
      {{- end }}
      - "$JS.API.STREAM.INFO.{{ $k8sInventoryStream }}"
      - "$JS.API.STREAM.CREATE.{{ $k8sInventoryStream }}"
      - "$JS.API.STREAM.UPDATE.{{ $k8sInventoryStream }}"
    {{- else }}
    allow: []
    {{- end }}
  subscribe:
    {{- if $k8sInventoryNatsEnabled }}
    allow: ["_INBOX.>"]
    {{- else }}
    allow: []
    {{- end }}
- user: "O=ServiceRadar"
  publish:
    allow: [">"]
  subscribe:
    allow: [">"]
{{- end -}}

{{- /*
serviceradar.natsSubjectArray renders a list of subjects as a NATS
configuration array on one line. The server configuration is written by an
unquoted shell heredoc, so `$` is escaped for the shell.
*/ -}}
{{- define "serviceradar.natsSubjectArray" -}}
[{{- range $i, $subject := . -}}{{- if $i }}, {{ end -}}"{{ replace "$" "\\$" $subject }}"{{- end -}}]
{{- end -}}
