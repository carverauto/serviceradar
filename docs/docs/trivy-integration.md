---
id: trivy-integration
title: Trivy Integration
sidebar_label: Trivy Integration
---

# Trivy Integration

Publish Trivy Operator report CRDs into ServiceRadar NATS JetStream using `trivy-sidecar`.

## Architecture

```
Trivy Operator CRDs (aquasecurity.github.io)
  -> serviceradar-trivy-sidecar
  -> NATS JetStream subjects trivy.report.>
  -> downstream ServiceRadar consumers
```

## Prerequisites

1. Kubernetes cluster with Trivy Operator CRDs installed.
2. ServiceRadar NATS available in-cluster.
3. NATS creds in `serviceradar-nats-creds` and certs in `serviceradar-runtime-certs`.
4. `trivy-sidecar` image pushed to GHCR.

## Build and Push Image

```bash
# Build and push all ServiceRadar images
make build
make push_all

# Capture current tag
git rev-parse HEAD
```

Set the sidecar image tag in [serviceradar-trivy-sidecar.yaml](/Users/mfreeman/src/serviceradar/k8s/demo/base/serviceradar-trivy-sidecar.yaml) before deploy.

## Deploy

```bash
# Apply dedicated RBAC + deployment manifest
kubectl apply -n demo -f k8s/demo/base/serviceradar-trivy-sidecar.yaml

# Confirm rollout
kubectl rollout status deployment/serviceradar-trivy-sidecar -n demo
kubectl get pods -n demo -l app=serviceradar-trivy-sidecar
```

## Create JetStream Stream

```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  nats --context serviceradar stream add trivy_reports \
  --subjects 'trivy.report.>' --storage file --retention limits --max-age 168h --defaults
```

## Verify Report Flow

1. Confirm Trivy CRDs exist:

```bash
kubectl api-resources | rg -i 'aquasecurity|vulnerabilityreport|configauditreport|rbacassessmentreport|infraassessmentreport|exposedsecretreport'
```

2. Watch sidecar logs:

```bash
kubectl -n demo logs deploy/serviceradar-trivy-sidecar -f
```

3. Subscribe to published subjects:

```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  nats --context serviceradar sub 'trivy.report.>'
```

4. Check stream stats:

```bash
kubectl -n demo exec deploy/serviceradar-tools -- \
  nats --context serviceradar stream info trivy_reports
```

5. Check health and metrics:

```bash
kubectl -n demo port-forward deploy/serviceradar-trivy-sidecar 9108:9108
curl -s http://127.0.0.1:9108/healthz
curl -s http://127.0.0.1:9108/readyz
curl -s http://127.0.0.1:9108/metrics
```

## Configuration

Environment variables supported by `trivy-sidecar`:

- `CLUSTER_ID` (required): cluster identifier added to each message.
- `NATS_HOSTPORT` (required): NATS URL.
- `NATS_SUBJECT_PREFIX` (default `trivy.report`).
- `NATS_STREAM` (default `trivy_reports`).
- `NATS_CREDSFILE`: JWT creds file.
- `NATS_CACERTFILE`: CA cert for TLS verification.
- `NATS_CERTFILE` / `NATS_KEYFILE`: optional mTLS client cert pair.
- `NATS_SERVER_NAME`: optional TLS SNI/server_name.
- `NATS_SKIP_TLS_VERIFY` (default `false`).
- `TRIVY_REPORT_GROUP_VERSION` (default `aquasecurity.github.io/v1alpha1`).
- `TRIVY_METRICS_ADDR` (default `:9108`).
- `TRIVY_INFORMER_RESYNC` (default `5m`).
- `TRIVY_PUBLISH_TIMEOUT` (default `5s`).
- `TRIVY_PUBLISH_MAX_RETRIES` (default `5`).
- `TRIVY_PUBLISH_RETRY_DELAY` (default `500ms`).
- `TRIVY_PUBLISH_MAX_RETRY_DELAY` (default `10s`).

## Troubleshooting

### Sidecar ready probe fails (`/readyz` is false)

- Check NATS connectivity and credentials.
- Verify Trivy report CRDs are installed.
- Confirm sidecar can list CRDs (`kubectl auth can-i list vulnerabilityreports --as=system:serviceaccount:demo:serviceradar-trivy-sidecar`).

### No messages in `trivy.report.>`

- Confirm stream exists and includes `trivy.report.>` subject.
- Confirm Trivy Operator is producing report objects (`kubectl get vulnerabilityreports.aquasecurity.github.io -A`).
- Restart sidecar after CRD installation if needed.

### TLS or auth errors to NATS

- Validate files under `/etc/serviceradar/creds` and `/etc/serviceradar/certs` inside the pod.
- Verify `NATS_SERVER_NAME` matches NATS certificate SAN.
- Ensure creds have publish permission for `trivy.report.>`.
