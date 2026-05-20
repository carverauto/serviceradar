---
id: falco
title: Falco
sidebar_label: Falco
---

# Falco Integration

Stream Falco runtime security events into ServiceRadar via NATS JetStream using Falcosidekick with mTLS authentication. Falcosidekick also exports OTLP metrics to the ServiceRadar log collector.

Falcosidekick should use the dedicated shared cert files:
- `/etc/serviceradar/certs/root.pem`
- `/etc/serviceradar/certs/falcosidekick.pem`
- `/etc/serviceradar/certs/falcosidekick-key.pem`

## Architecture

```
┌─────────┐     ┌───────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Falco   │────▶│ Falcosidekick │────▶│ NATS JetStream   │────▶│ ServiceRadar │
│ DaemonSet│     │  (Helm)       │     │ falco.>           │     │  Pipeline    │
└─────────┘     └───────────────┘     └──────────────────┘     └──────────────┘
                  │
                  └──▶ OTLP Metrics ──▶ ServiceRadar Log Collector
```

- **Falco** detects suspicious syscalls and k8s audit events on each node.
- **Falcosidekick** forwards events to NATS (mTLS) and exports OTLP metrics.
- **ServiceRadar** EventWriter uses dual-path ingestion:
  - Writes all Falco payloads to `platform.logs` as raw records.
  - Auto-promotes `Warning` and higher priorities to `platform.ocsf_events`.
  - Evaluates `Critical` and higher promoted events with a seeded stateful alert rule.

## Incident-Based Alerting

Falco alerting is incident-based rather than one-alert-per-event:

- Repeated critical detections for the same Falco rule and host update one active alert incident.
- The active alert records duplicate metadata such as occurrence count, first seen, last seen, and grouping values.
- Immediate notification attempts happen on incident creation and then follow the rule's cooldown and renotify settings.
- Raw Falco logs and promoted OCSF events are still stored individually for audit and investigation.

The default seeded Falco incident rule groups by `rule` and `hostname`, uses a 5-minute cooldown, and renotifies long-lived incidents every 6 hours.

Operators can review and tune these settings in **Settings → Events → Alerts** by editing the Falco stateful alert rule.

## Prerequisites

1. **Falco** installed as a DaemonSet (via Helm).
2. **ServiceRadar** stack running with NATS, log-collector, and tools pods.
3. ServiceRadar mTLS certificates available in the cluster, mounted from the
   `serviceradar-runtime-certs` secret. The expected files are:
   - `/etc/serviceradar/certs/root.pem`
   - `/etc/serviceradar/certs/falcosidekick.pem`
   - `/etc/serviceradar/certs/falcosidekick-key.pem`
4. Helm repos configured:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
```

The examples below use `<namespace>` for the ServiceRadar namespace and
`<release-name>` for the Falcosidekick Helm release. Substitute the values that
match your environment.

## Step 1: Create a Falcosidekick Collector Package

### Via the UI

1. Navigate to **Settings > Edge Ops > Collectors**.
2. Click **New Collector**.
3. Select **Falcosidekick (Falco)** as the collector type.
4. Set the **Site** to your cluster/namespace.
5. Click **Create Collector**.
6. Download the bundle — it contains Helm values, a deploy script, and NATS credentials metadata.

### Via the API

```bash
curl -X POST https://your-instance.serviceradar.cloud/api/admin/collectors \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "collector_type": "falcosidekick",
    "site": "<namespace>",
    "config_overrides": {
      "namespace": "<namespace>",
      "release_name": "<release-name>"
    }
  }'
```

## Step 2: Deploy with the Bundle

Download and extract the bundle, then run the deploy script:

```bash
# Download and extract
SR_TOKEN="${SERVICERADAR_DOWNLOAD_TOKEN:-}"
if [ -z "$SR_TOKEN" ]; then
  read -rsp "Download token: " SR_TOKEN
  echo
fi

curl -fsSL -X POST \
  -H "x-serviceradar-download-token: ${SR_TOKEN}" \
  "https://your-instance.serviceradar.cloud/api/collectors/<ID>/bundle" | tar xzf -

cd collector-package-*/

# Deploy (verifies runtime cert secret + helm upgrade)
./deploy.sh
```

### Bundle Contents

```
collector-package-<id>/
├── creds/
│   └── nats.creds            # NATS credentials (for future .creds auth)
├── falcosidekick.yaml         # Helm values
├── deploy.sh                  # Automated deploy script
└── README.md
```

### What `deploy.sh` Does

1. Verifies the shared Kubernetes secret `serviceradar-runtime-certs` exists in the target namespace
2. Runs `helm upgrade --install` with the generated `falcosidekick.yaml` values

### Manual Deploy

If you prefer to deploy manually:

```bash
# Confirm the shared runtime cert secret exists
kubectl get secret serviceradar-runtime-certs \
  --namespace <namespace>

# Deploy Falcosidekick
helm upgrade --install <release-name> falcosecurity/falcosidekick \
  --namespace <namespace> \
  --set podSecurityContext.runAsUser=1234 \
  --set podSecurityContext.fsGroup=1234 \
  --set securityContext.allowPrivilegeEscalation=false \
  --set securityContext.runAsNonRoot=true \
  --set securityContext.capabilities.drop[0]=ALL \
  --set securityContext.seccompProfile.type=RuntimeDefault \
  -f falcosidekick.yaml
```

If the collector bundle is not available, you can configure NATS, OTLP metrics,
and the ServiceRadar cert mounts inline instead of using a values file:

```bash
helm upgrade --install <release-name> falcosecurity/falcosidekick \
  --namespace <namespace> \
  --reuse-values \
  --set podSecurityContext.runAsUser=1234 \
  --set podSecurityContext.fsGroup=1234 \
  --set securityContext.allowPrivilegeEscalation=false \
  --set securityContext.runAsNonRoot=true \
  --set securityContext.capabilities.drop[0]=ALL \
  --set securityContext.seccompProfile.type=RuntimeDefault \
  --set-string config.nats.hostport=nats://serviceradar-nats:4222 \
  --set config.nats.mutualtls=true \
  --set config.nats.checkcert=true \
  --set-string config.nats.subjecttemplate='falco.<priority>.<rule>' \
  --set-string config.nats.minimumpriority=debug \
  --set-string config.tlsclient.cacertfile=/etc/serviceradar/certs/root.pem \
  --set-string config.mutualtlsclient.cacertfile=/etc/serviceradar/certs/root.pem \
  --set-string config.mutualtlsclient.certfile=/etc/serviceradar/certs/falcosidekick.pem \
  --set-string config.mutualtlsclient.keyfile=/etc/serviceradar/certs/falcosidekick-key.pem \
  --set-string config.otlp.metrics.endpoint=https://serviceradar-log-collector:4317 \
  --set-string config.otlp.metrics.protocol=grpc \
  --set config.otlp.metrics.checkcert=true \
  --set-string config.otlp.metrics.minimumpriority=debug \
  --set-string config.otlp.metrics.extraenvvars.OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE=/etc/serviceradar/certs/root.pem \
  --set-string config.otlp.metrics.extraenvvars.OTEL_EXPORTER_OTLP_METRICS_CLIENT_CERTIFICATE=/etc/serviceradar/certs/falcosidekick.pem \
  --set-string config.otlp.metrics.extraenvvars.OTEL_EXPORTER_OTLP_METRICS_CLIENT_KEY=/etc/serviceradar/certs/falcosidekick-key.pem \
  --set extraVolumes[0].name=serviceradar-certs \
  --set extraVolumes[0].secret.secretName=serviceradar-runtime-certs \
  --set extraVolumeMounts[0].name=serviceradar-certs \
  --set extraVolumeMounts[0].mountPath=/etc/serviceradar/certs \
  --set extraVolumeMounts[0].readOnly=true

kubectl -n <namespace> rollout status deploy/<release-name>
```

The `falcosecurity/falcosidekick` chart is versioned independently of
ServiceRadar. Pin a `--version` only if you need a reproducible deploy; check
the [chart repo](https://github.com/falcosecurity/charts) for the current
release.

Important:

- Use `https://serviceradar-log-collector:4317` for OTLP gRPC TLS.
  A plaintext `http://...:4317` endpoint will typically fail with
  `unexpected EOF`.
- Use the service name `serviceradar-log-collector` — it matches the cert SANs
  in the ServiceRadar default certificates.

## Step 3: Configure Falco to Forward Events

If Falco only writes to stdout/syslog, Falcosidekick will only receive `/test`
traffic and no live Falco events. Falco must have HTTP + JSON output enabled and
pointed at Falcosidekick:

```bash
helm upgrade -n falco falco falcosecurity/falco \
  --reuse-values \
  --set falco.json_output=true \
  --set falco.http_output.enabled=true \
  --set-string falco.http_output.url=http://<release-name>.<namespace>.svc.cluster.local:2801/
```

Wait for the rollout:

```bash
kubectl -n falco rollout status ds/falco
```

As with Falcosidekick, the `falcosecurity/falco` chart is versioned
independently — check the chart repo for the current version if you need to pin
one.

## Step 4: Optional — Create a JetStream Stream

For dedicated retention and visibility of Falco events:

```bash
kubectl -n <namespace> exec deploy/serviceradar-tools -- \
  nats --context serviceradar stream add falco_events \
  --subjects 'falco.>' --storage file --retention limits --max-age 24h --defaults
```

## Step 5: Verify End-to-End

### Check Falcosidekick Logs

```bash
kubectl -n <namespace> logs deploy/<release-name> --tail=20
```

Look for:
- `Enabled Outputs: [NATS OTLPMetrics]`
- `NATS - Publish OK`

### Send a Test Event

```bash
kubectl -n <namespace> exec deploy/serviceradar-tools -- \
  curl -s -X POST -o /dev/null -w '%{http_code}\n' \
  http://<release-name>:2801/test
```

Expected: `200`

### Subscribe to Falco Events

```bash
kubectl -n <namespace> exec deploy/serviceradar-tools -- \
  nats --context serviceradar sub 'falco.>'
```

### Verify Promoted OCSF Events (Warning+)

```bash
kubectl -n <namespace> exec cnpg-1 -- psql -U serviceradar -d serviceradar \
  -c "SELECT time, severity, status, message, log_name FROM ocsf_events WHERE log_provider = 'falco' ORDER BY time DESC LIMIT 20;"
```

### Verify Raw Log Persistence

```bash
kubectl -n <namespace> exec cnpg-1 -- psql -U serviceradar -d serviceradar \
  -c "SELECT timestamp, severity_text, body, source FROM logs WHERE source = 'falco' ORDER BY timestamp DESC LIMIT 20;"
```

### Verify Alert Incidents (Critical/Fatal)

```bash
kubectl -n <namespace> exec cnpg-1 -- psql -U serviceradar -d serviceradar \
  -c "SELECT id, severity, title, status, metadata->>'incident_occurrence_count' AS occurrences, metadata->>'incident_last_seen_at' AS last_seen FROM alerts ORDER BY created_at DESC LIMIT 20;"
```

### Trigger a Real Falco Event

Execute into a pod to trigger Falco's `Terminal shell in container` rule:

```bash
kubectl exec -it deployment/some-app -- /bin/sh
```

You should see the event arrive on the `falco.>` subjects within seconds.

### Check OTLP Metrics

```bash
kubectl -n <namespace> exec deploy/serviceradar-tools -- \
  nats --context serviceradar sub 'otel.metrics.raw'
```

### Verify the Collector Sees OTLP Metrics

```bash
kubectl -n <namespace> logs deploy/serviceradar-log-collector --since=10m | \
  grep -E 'OTEL metrics export request|published raw OTLP metrics'
```

## Troubleshooting

### Only `/test` Events — No Live Falco Events

Check that Falco HTTP output is configured:

```bash
kubectl -n falco get cm falco -o jsonpath='{.data.falco\.yaml}' | \
  grep -E 'json_output|http_output|url:'
```

Required settings:
- `json_output: true`
- `http_output.enabled: true`
- `http_output.url` points to the Falcosidekick service

### NATS TLS Errors (`unknown authority`, `certificate required`)

- Verify cert files are mounted: `kubectl -n <namespace> exec deploy/<release-name> -- ls /etc/serviceradar/certs/`
- Ensure `config.nats.mutualtls=true` in the Helm values
- Ensure the pod is mounting `serviceradar-runtime-certs`
- Check that the CA trust chain matches the NATS server certificate
- Confirm the `config.mutualtlsclient.{certfile,keyfile,cacertfile}` paths and service DNS

### OTLP Exporter Shows `unexpected EOF` / `error reading server preface`

This is caused by using a plaintext endpoint (`http://...:4317`) against the
TLS gRPC listener.

- Use `https://serviceradar-log-collector:4317` (not `http://`)
- Use the service name that matches the cert SANs (e.g., `serviceradar-log-collector`)
- Provide the CA/client cert/key env vars shown in Step 2

### Events Not Arriving in ServiceRadar

1. Confirm Falco generates events: `kubectl -n falco logs ds/falco --tail=10`
2. Confirm Falcosidekick receives them: check for incoming payloads in Falcosidekick logs
3. Confirm NATS connectivity: `nats server check connection` from the tools pod

## Quick Sanity Commands

```bash
kubectl -n <namespace> get pods | grep falcosidekick
kubectl -n falco get pods | grep '^falco-'
kubectl -n <namespace> exec deploy/serviceradar-tools -- nats --context serviceradar stream ls
kubectl -n <namespace> exec deploy/serviceradar-tools -- nats --context serviceradar stream info falco_events
```

## Helm Values Reference

The generated `falcosidekick.yaml` configures:

| Setting | Description |
|---------|-------------|
| `config.nats.hostport` | NATS server URL |
| `config.nats.mutualtls` | Enable mTLS authentication |
| `config.nats.subjecttemplate` | Subject pattern (`falco.<priority>.<rule>`) |
| `config.mutualtlsclient.*` | Client cert, key, and CA paths |
| `config.otlp.metrics.*` | OTLP gRPC metrics export to log-collector |
| `extraVolumes` / `extraVolumeMounts` | Mount the cert secret into the pod |
