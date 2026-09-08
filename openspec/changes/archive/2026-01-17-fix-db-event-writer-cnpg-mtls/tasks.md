## 1. Implementation
- [x] 1.1 Set CNPG_CERT_FILE and CNPG_KEY_FILE env vars for the db-event-writer Helm deployment to cnpg-client certificate paths.
- [x] 1.2 Add CNPG_CA_FILE, CNPG_CERT_FILE, and CNPG_KEY_FILE env vars to the demo kustomize db-event-writer deployment.
- [x] 1.3 Update entrypoint-db-event-writer.sh defaults to prefer cnpg-client.pem/cnpg-client-key.pem for CNPG TLS when env overrides are not set.
- [x] 1.4 Update demo db-event-writer config template to reference cnpg-client certificate paths.
- [x] 1.5 Add a short troubleshooting note in docs/docs/agents.md covering CNPG client cert wiring for db-event-writer.
- [x] 1.6 Ensure demo cert generation includes the cnpg-client certificate bundle.
