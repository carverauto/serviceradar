## ADDED Requirements

### Requirement: Helm demo chart renders complete shared config
The Helm deployment SHALL render and apply a `serviceradar-config` ConfigMap that includes all service configs, including `nats.conf`, when installing the demo stack.

#### Scenario: ConfigMap contains NATS configuration
- **GIVEN** a Helm render using the demo values
- **WHEN** the manifest for `serviceradar-config` is generated
- **THEN** the data section includes a `nats.conf` key with server settings for NATS

### Requirement: NATS uses directory-mounted config
The NATS deployment SHALL mount its ConfigMap to a directory path and point the server `--config` flag to that directory file to avoid subPath mount errors.

#### Scenario: NATS starts with directory-mounted config
- **GIVEN** the NATS pod is created from the chart
- **WHEN** the pod starts
- **THEN** the container uses `/etc/nats-config/nats-server.conf` from a ConfigMap-mounted directory and the pod reaches Ready

### Requirement: Demo chart provisions required storage and credentials
The Helm deployment SHALL create the core data PVC and a `cnpg-superuser` secret (username/password) so core and dependent workloads can bind storage and connect to CNPG without manual steps.

#### Scenario: PVC and cnpg-superuser exist after install
- **GIVEN** the chart is installed into an empty namespace with the demo values
- **THEN** a PVC named `serviceradar-core-data` exists and is bound by core
- **AND** a secret `cnpg-superuser` exists with `username` and `password` keys

### Requirement: Optional components are gated for demo installs
The Helm deployment SHALL allow Proton and the SPIRE controller manager to be disabled via values, with Proton disabled by default for the demo install.

#### Scenario: Proton disabled in demo values
- **GIVEN** the demo values are applied
- **THEN** Proton is not deployed and its PVCs/RS are not created
- **AND** the SPIRE controller manager sidecar is not started when `enabled=false`
