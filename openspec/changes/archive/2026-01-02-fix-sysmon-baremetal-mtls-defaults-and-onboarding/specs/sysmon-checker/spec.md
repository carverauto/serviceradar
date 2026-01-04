## ADDED Requirements

### Requirement: Bare‑metal sysmon seeds an mTLS default config
When sysmon is installed via RPM/Deb on bare metal and no explicit configuration exists, the checker SHALL seed and ship a default configuration that uses mTLS security.

#### Scenario: First start on bare metal without config
- **GIVEN** `serviceradar-sysmon-checker` is installed via RPM/Deb and `/etc/serviceradar/checkers/sysmon.json` does not exist
- **WHEN** the systemd unit starts the service
- **THEN** sysmon SHALL create `/etc/serviceradar/checkers/sysmon.json` from its embedded default template
- **AND** the generated `security` block SHALL use `mode: "mtls"` with:
  - `cert_dir: "/etc/serviceradar/certs"`
  - `cert_file: "sysmon.pem"`
  - `key_file: "sysmon-key.pem"`
  - `ca_file: "root.pem"`
- **AND** sysmon SHALL start successfully without requiring a SPIRE agent or workload socket.

### Requirement: SPIFFE remains an explicit opt‑in for bare metal
Sysmon SHALL continue to support SPIFFE/SPIRE mode, but it SHALL only be enabled on bare‑metal installs when explicitly configured.

#### Scenario: Operator enables SPIFFE mode
- **GIVEN** an operator provides a config (file or KV) with `security.mode: "spiffe"` and required SPIFFE fields (`trust_domain`, `workload_socket`, optional `server_spiffe_id`)
- **WHEN** sysmon loads configuration
- **THEN** sysmon SHALL validate SPIFFE fields and start using workload API credentials.

