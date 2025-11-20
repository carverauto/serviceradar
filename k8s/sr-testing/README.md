# SR Testing Fixtures

This namespace hosts lightweight, disposable dependencies for KV/JetStream integration testing. It keeps CI-friendly infrastructure separate from demo workloads.

## Contents

- `namespace.yaml` – creates the `sr-testing` namespace.
- `configmap.yaml` – NATS server config (JetStream + TLS required).
- `nats.yaml` – single-replica NATS server with JetStream enabled, using an `emptyDir` volume for ephemeral storage and TLS enforced.
- `tls-secret.yaml` – template for the TLS secret if you want to pre-create it manually.
- `generate-nats-certs.sh` – helper to mint a self-signed CA + server/client certs and create the `sr-testing-nats-tls` secret.
- `kustomization.yaml` – applies the namespace and NATS resources together (expects `sr-testing-nats-tls` to exist).
- `nats-ext-service.yaml` – LoadBalancer service with MetalLB + ExternalDNS annotations for public reachability.
- `export-nats-env.sh` – fetches the client certs from the secret and prints the env exports for local Bazel runs.

## Usage

```bash
# One-time: generate self-signed certs and create the secret
./k8s/sr-testing/generate-nats-certs.sh

# Deploy namespace + NATS once the secret exists
kubectl apply -k k8s/sr-testing
kubectl -n sr-testing get pods -w
```

The NATS service is exposed in-cluster at `sr-testing-nats.sr-testing.svc.cluster.local:4222` (TLS). JetStream monitoring is available on port `8222` (HTTP). Client certs are required; use the `client.crt`/`client.key` emitted by the generator script.

For GitHub/BuildBuddy runners inside the cluster, use the cluster DNS name above. For external consumers, use the LoadBalancer service `sr-testing-nats-ext` (hostname `sr-testing-nats.serviceradar.cloud` via ExternalDNS).

### Client environment (Go/Rust tests)

Point clients at the fixture using mTLS:

```bash
export NATS_URL="tls://sr-testing-nats.sr-testing.svc.cluster.local:4222"
export NATS_CA_FILE=/path/to/ca.crt
export NATS_CERT_FILE=/path/to/client.crt
export NATS_KEY_FILE=/path/to/client.key
export NATS_SERVER_NAME=sr-testing-nats
```

To pull the secret locally and set the environment quickly:

```bash
./k8s/sr-testing/export-nats-env.sh
```

For in-cluster test jobs, mount the `sr-testing-nats-tls` secret and reference the mounted paths. For port-forwarding locally:

```bash
kubectl -n sr-testing port-forward svc/sr-testing-nats 4222:4222 &
export NATS_URL="tls://127.0.0.1:4222"
# Keep NATS_SERVER_NAME=sr-testing-nats so the SAN check passes
```

For Bazel/BuildBuddy, pass the NATS settings through with `--action_env`, for example:

```bash
bazel test //tests/kvseeding:kvseeding_test \
  --action_env=NATS_URL \
  --action_env=NATS_CA_FILE \
  --action_env=NATS_CERT_FILE \
  --action_env=NATS_KEY_FILE \
  --action_env=NATS_SERVER_NAME
```

## Next Steps

- Wire KV seeding integration tests to target `sr-testing-nats`.
- Add per-service test cases that start with an empty KV bucket and assert the initial seed matches the defaults shipped in `packaging/`.
