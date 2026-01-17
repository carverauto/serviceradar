# Change: Fix db-event-writer CNPG mTLS wiring

## Why
The db-event-writer entrypoint currently overwrites CNPG TLS settings to use the db-event-writer service certificate, and the Kubernetes manifests do not set CNPG client cert/key overrides. When CNPG requires client certificates, this results in TLS handshake failures and db-event-writer cannot connect to CNPG, blocking ingestion.

## What Changes
- Wire CNPG client certificate/key environment variables for db-event-writer in Helm and demo kustomize manifests.
- Update the db-event-writer entrypoint defaults to prefer the CNPG client certificate bundle (cnpg-client.pem/cnpg-client-key.pem) instead of the service cert when CNPG mTLS is enabled.
- Align demo db-event-writer config to reference the CNPG client cert bundle so the entrypoint does not rewrite it incorrectly.

## Impact
- Affected specs: cnpg
- Affected code: helm/serviceradar/templates/db-event-writer.yaml, docker/compose/entrypoint-db-event-writer.sh, k8s/demo/base/serviceradar-db-event-writer.yaml, k8s/demo/base/serviceradar-db-event-writer-config.yaml
