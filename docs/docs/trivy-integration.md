---
id: trivy-integration
title: Trivy Integration
sidebar_label: Trivy Integration
---

# Trivy Integration

ServiceRadar supports a [Trivy](https://trivy.dev/) integration for container image
vulnerability scanning. Trivy scans your container images for known CVEs and
misconfigurations, and the findings flow into ServiceRadar alongside the rest of
your telemetry.

## What It Does

The integration runs Trivy as a sidecar scanner alongside your workloads. It scans
container images for known CVEs and misconfigurations, then publishes the results as
structured vulnerability reports.

- **Scanning**: Trivy inspects container images and produces vulnerability findings
  (CVE ID, severity, affected package, fixed version).
- **Transport**: Reports are published over NATS JetStream on the `trivy.report.>`
  subject hierarchy.
- **Ingestion**: The core event-writer pipeline consumes those messages and persists
  them to the `trivy_reports` table in CNPG, where retention is managed alongside the
  rest of ServiceRadar's telemetry.
- **Querying**: Once ingested, vulnerability data is available for review through the
  ServiceRadar UI and SRQL like any other dataset.

## Kubernetes Setup With Helm

Use this path when Trivy Operator and ServiceRadar run in Kubernetes. Install
Trivy Operator first, then enable the ServiceRadar sidecar that watches Trivy
report CRDs and publishes them into JetStream.

### Step 1: Install Trivy Operator

```bash
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update

helm upgrade --install trivy-operator aqua/trivy-operator \
  --namespace trivy-system \
  --create-namespace
```

Confirm that report CRDs are installed:

```bash
kubectl api-resources --api-group aquasecurity.github.io
```

### Step 2: Enable The ServiceRadar Trivy Sidecar

The ServiceRadar Helm chart ships the Trivy publisher as
`serviceradar-trivy-sidecar`. It is disabled by default.

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  --namespace <namespace> \
  -f helm/serviceradar/values.yaml \
  --set trivySidecar.enabled=true
```

For production, keep the sidecar on the same release tag as the rest of
ServiceRadar:

```yaml
trivySidecar:
  enabled: true
  clusterId: production
  nats:
    hostPort: tls://serviceradar-nats:4222
    subjectPrefix: trivy.report
    stream: trivy_reports
    caCertFile: /etc/serviceradar/certs/ca.crt
    certFile: /etc/serviceradar/certs/trivy-sidecar.pem
    keyFile: /etc/serviceradar/certs/trivy-sidecar-key.pem
    serverName: serviceradar-nats
```

The chart also creates:

- A `ServiceAccount` named `serviceradar-trivy-sidecar`.
- Read-only RBAC for Trivy Operator report CRDs and pods.
- A metrics service on port `9108`.
- Runtime cert mounts from `serviceradar-runtime-certs`.

### Step 3: Verify The JetStream Stream

The sidecar publishes to `trivy.report.>` and creates or updates the
`trivy_reports` stream when it starts. You can verify it from the tools pod:

```bash
kubectl -n <namespace> exec deploy/serviceradar-tools -- \
  nats --context serviceradar stream info trivy_reports
```

### Step 4: Verify Sidecar Health And Publishing

```bash
kubectl -n <namespace> rollout status deploy/serviceradar-trivy-sidecar
kubectl -n <namespace> logs deploy/serviceradar-trivy-sidecar --tail=50
kubectl -n <namespace> port-forward svc/serviceradar-trivy-sidecar 9108:9108
curl -fsS http://127.0.0.1:9108/metrics | grep trivy_sidecar_published_total
```

### Step 5: Verify Ingestion

```bash
kubectl -n <namespace> exec deploy/serviceradar-tools -- \
  nats --context serviceradar stream info trivy_reports

kubectl -n <namespace> exec cnpg-1 -- psql -U serviceradar -d serviceradar \
  -c "SELECT kind, resource_namespace, resource_name, created_at FROM platform.trivy_reports ORDER BY created_at DESC LIMIT 20;"

kubectl -n <namespace> exec cnpg-1 -- psql -U serviceradar -d serviceradar \
  -c "SELECT severity, finding_class, title FROM platform.trivy_findings ORDER BY observed_at DESC LIMIT 20;"
```

## Docker Compose Setup

Use this path when the ServiceRadar control plane runs with `docker compose`.
The Trivy sidecar still watches a Kubernetes cluster through kubeconfig; Compose
provides the local NATS/CNPG/UI sink.

### Step 1: Start ServiceRadar With EventWriter Enabled

```bash
APP_TAG=sha-<release-sha> EVENT_WRITER_ENABLED=true docker compose up -d
```

Regenerate certs if your `cert-data` volume was created before the
`trivy-sidecar` certificate existed:

```bash
docker compose run --rm cert-generator
docker compose up -d nats core-elx
```

### Step 2: Run The Sidecar On The Compose Network

Export or copy a kubeconfig that can read Trivy Operator report CRDs:

```bash
export KUBECONFIG=$HOME/.kube/config
```

Run the sidecar container:

```bash
docker run --rm --name serviceradar-trivy-sidecar \
  --network serviceradar-net \
  -p 9108:9108 \
  -e CLUSTER_ID=compose-dev \
  -e KUBECONFIG=/kube/config \
  -e NATS_HOSTPORT=tls://nats:4222 \
  -e NATS_CREDSFILE=/etc/serviceradar/creds/platform.creds \
  -e NATS_CACERTFILE=/etc/serviceradar/certs/root.pem \
  -e NATS_CERTFILE=/etc/serviceradar/certs/trivy-sidecar.pem \
  -e NATS_KEYFILE=/etc/serviceradar/certs/trivy-sidecar-key.pem \
  -e NATS_SERVER_NAME=nats.serviceradar \
  -e NATS_SUBJECT_PREFIX=trivy.report \
  -e NATS_STREAM=trivy_reports \
  -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
  -v serviceradar_nats-creds:/etc/serviceradar/creds:ro \
  -v "$KUBECONFIG:/kube/config:ro" \
  registry.carverauto.dev/serviceradar/serviceradar-trivy-sidecar:${APP_TAG:-latest}
```

If the Kubernetes API in your kubeconfig is not reachable from Docker, use a
kubeconfig whose server address is reachable from the Docker host or add a
Docker host route for that API endpoint.

### Step 3: Verify Compose Ingestion

```bash
docker compose exec tools nats --context serviceradar stream info trivy_reports
curl -fsS http://127.0.0.1:9108/metrics | grep trivy_sidecar_published_total
docker compose exec cnpg psql -U serviceradar -d serviceradar \
  -c "SELECT kind, resource_namespace, resource_name FROM platform.trivy_reports ORDER BY created_at DESC LIMIT 20;"
```

## Verifying

- Check that messages are arriving in the `trivy_reports` JetStream stream.
- Confirm rows are landing in `platform.trivy_reports` and `platform.trivy_findings`.
- Review findings through the ServiceRadar UI and the `/security` page.

## Troubleshooting

### Sidecar Is Healthy But Stream Has Zero Messages

Check Trivy Operator CRDs and reports:

```bash
kubectl api-resources --api-group aquasecurity.github.io
kubectl get vulnerabilityreports --all-namespaces
```

If reports exist but NATS is empty, check the sidecar logs and metrics:

```bash
kubectl -n <namespace> logs deploy/serviceradar-trivy-sidecar --tail=100
curl -fsS http://127.0.0.1:9108/metrics | grep trivy_sidecar_publish
```

### NATS TLS Or Permission Errors

- Confirm `trivy-sidecar.pem`, `trivy-sidecar-key.pem`, and `root.pem` are mounted.
- Confirm the runtime cert secret exists in Helm installs:
  `kubectl -n <namespace> get secret serviceradar-runtime-certs`.
- Confirm the sidecar uses `NATS_CREDSFILE` in Docker Compose, because the compose
  NATS server uses account JWT credentials in addition to mTLS.
