# ServiceRadar Integration Guide (Falco + Falcosidekick + NATS + OTLP)

This guide shows how to run Falcosidekick in a ServiceRadar environment with:

- NATS mTLS publishing
- OTLP metrics export to ServiceRadar collector (`4317`)
- Falco forwarding to Falcosidekick

Examples below use:

- Kubernetes namespace: `demo`
- Sidekick release: `falcosidekick-nats-auth`
- Falco release: `falco` in namespace `falco`

## 1. Prerequisites

1. ServiceRadar stack running in `demo` with:
- `serviceradar-nats`
- `serviceradar-log-collector`
- `serviceradar-tools`

2. ServiceRadar certs available in the cluster (expected files):
- `/etc/serviceradar/certs/root.pem`
- `/etc/serviceradar/certs/client.pem`
- `/etc/serviceradar/certs/client-key.pem`

3. Helm repos:
```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
```

## 2. Deploy/Update Falcosidekick for ServiceRadar

Use this to configure NATS + OTLP metrics and mount ServiceRadar certs.

```bash
helm upgrade -n demo falcosidekick-nats-auth falcosecurity/falcosidekick \
  --version 0.13.0 \
  --reuse-values \
  --set-string config.nats.hostport=nats://serviceradar-nats:4222 \
  --set config.nats.mutualtls=true \
  --set config.nats.checkcert=true \
  --set-string config.nats.subjecttemplate='falco.<priority>.<rule>' \
  --set-string config.nats.minimumpriority=debug \
  --set-string config.tlsclient.cacertfile=/etc/serviceradar/certs/root.pem \
  --set-string config.mutualtlsclient.cacertfile=/etc/serviceradar/certs/root.pem \
  --set-string config.mutualtlsclient.certfile=/etc/serviceradar/certs/client.pem \
  --set-string config.mutualtlsclient.keyfile=/etc/serviceradar/certs/client-key.pem \
  --set-string config.otlp.metrics.endpoint=https://serviceradar-log-collector:4317 \
  --set-string config.otlp.metrics.protocol=grpc \
  --set config.otlp.metrics.checkcert=true \
  --set-string config.otlp.metrics.minimumpriority=debug \
  --set-string config.otlp.metrics.extraenvvars.OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE=/etc/serviceradar/certs/root.pem \
  --set-string config.otlp.metrics.extraenvvars.OTEL_EXPORTER_OTLP_METRICS_CLIENT_CERTIFICATE=/etc/serviceradar/certs/client.pem \
  --set-string config.otlp.metrics.extraenvvars.OTEL_EXPORTER_OTLP_METRICS_CLIENT_KEY=/etc/serviceradar/certs/client-key.pem \
  --set extraVolumes[0].name=serviceradar-certs \
  --set extraVolumes[0].secret.secretName=serviceradar-runtime-certs \
  --set extraVolumeMounts[0].name=serviceradar-certs \
  --set extraVolumeMounts[0].mountPath=/etc/serviceradar/certs \
  --set extraVolumeMounts[0].readOnly=true

kubectl -n demo rollout status deploy/falcosidekick-nats-auth
```

Important:

- Use `https://serviceradar-log-collector:4317` for OTLP gRPC TLS.
- `http://...:4317` will typically fail with `unexpected EOF`.
- Use service name `serviceradar-log-collector` (matches cert SANs in ServiceRadar default certs).

## 3. Configure Falco to Send Alerts to Falcosidekick

If Falco only writes to stdout/syslog, Sidekick will only receive `/test` traffic and no live Falco events.

Enable Falco HTTP output + JSON output:

```bash
helm upgrade -n falco falco falcosecurity/falco \
  --version 8.0.1 \
  --reuse-values \
  --set falco.json_output=true \
  --set falco.http_output.enabled=true \
  --set-string falco.http_output.url=http://falcosidekick-nats-auth.demo.svc.cluster.local:2801/

kubectl -n falco rollout status ds/falco
```

## 4. Optional JetStream Stream for Falco Subjects

If you want dedicated retention/visibility for Falco alerts:

```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  nats --context serviceradar stream add falco_events \
  --subjects 'falco.>' --storage file --retention limits --max-age 24h --defaults
```

## 5. Validate End-to-End

### Sidekick health and outputs
```bash
kubectl -n demo logs deploy/falcosidekick-nats-auth --since=10m
```

Look for:
- `Enabled Outputs: [NATS OTLPMetrics]`
- `NATS - Publish OK`

### Sidekick test event
```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  curl -s -X POST -o /dev/null -w '%{http_code}\n' http://falcosidekick-nats-auth:2801/test
```

Expected: `200`

### Subscribe to Falco subjects in NATS
```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  nats --context serviceradar sub 'falco.>'
```

### Check OTLP metrics raw subject
```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  nats --context serviceradar sub 'otel.metrics.raw'
```

### Verify collector sees OTLP metrics
```bash
kubectl -n demo logs deploy/serviceradar-log-collector --since=10m | \
  grep -E 'OTEL metrics export request|published raw OTLP metrics'
```

## 6. Troubleshooting

### Symptom: only `/test` events show up, no live Falco events
Check Falco output settings:

```bash
kubectl -n falco get cm falco -o jsonpath='{.data.falco\.yaml}' | \
  grep -E 'json_output|http_output|url:'
```

Required:
- `json_output: true`
- `http_output.enabled: true`
- `http_output.url` points to Sidekick service

### Symptom: OTLP exporter shows `error reading server preface: unexpected EOF`
Cause:
- Using plaintext endpoint (`http://...:4317`) against TLS gRPC listener.

Fix:
- Use `https://serviceradar-log-collector:4317`
- Provide CA/client cert/key env vars shown in Section 2.

### Symptom: NATS TLS errors (`unknown authority`, `certificate required`, handshake failures)
Check:
- cert files mounted in Sidekick pod
- `config.nats.mutualtls=true`
- `config.mutualtlsclient.{certfile,keyfile,cacertfile}` paths
- service DNS and CA trust chain

## 7. Quick Sanity Commands

```bash
kubectl -n demo get pods | grep falcosidekick
kubectl -n falco get pods | grep '^falco-'
kubectl -n demo exec deploy/serviceradar-tools -- nats --context serviceradar stream ls
kubectl -n demo exec deploy/serviceradar-tools -- nats --context serviceradar stream info falco_events
```
