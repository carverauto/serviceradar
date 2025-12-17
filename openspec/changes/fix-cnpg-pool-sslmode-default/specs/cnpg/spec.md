## ADDED Requirements
### Requirement: CNPG client connections default to TLS when configured
ServiceRadar components that connect to CNPG using `models.CNPGDatabase` MUST negotiate TLS when `tls` configuration is provided, even if `ssl_mode` is not explicitly set.

#### Scenario: TLS config without ssl_mode uses verify-full
- **GIVEN** a `models.CNPGDatabase` configuration with `tls` set and `ssl_mode` unset
- **WHEN** a component builds its CNPG connection pool using `pkg/db/cnpg_pool.go:NewCNPGPool`
- **THEN** the connection attempts TLS using the provided client certificate and CA, with `ssl_mode` defaulting to `verify-full`.

#### Scenario: No TLS config preserves plaintext defaults
- **GIVEN** a `models.CNPGDatabase` configuration with `tls` unset and `ssl_mode` unset
- **WHEN** a component builds its CNPG connection pool
- **THEN** the connection defaults to `ssl_mode=disable` for local/dev compatibility unless explicitly configured otherwise.

### Requirement: CNPG client configuration rejects insecure contradictions
ServiceRadar MUST reject CNPG configurations where `tls` is provided but `ssl_mode` is explicitly set to `disable`.

#### Scenario: tls + ssl_mode=disable fails fast
- **GIVEN** a `models.CNPGDatabase` configuration with `tls` set and `ssl_mode=disable`
- **WHEN** a component attempts to build its CNPG connection pool
- **THEN** pool initialization fails with an error describing the invalid configuration.

### Requirement: CNPG clients honor explicit ssl_mode overrides
When `ssl_mode` is explicitly set, ServiceRadar MUST honor the configured value (e.g., `require`, `verify-ca`, `verify-full`) subject to validation rules.

#### Scenario: Explicit verify-ca is preserved
- **GIVEN** a `models.CNPGDatabase` configuration with `tls` set and `ssl_mode=verify-ca`
- **WHEN** a component builds its CNPG connection pool
- **THEN** the connection attempts TLS and uses `ssl_mode=verify-ca`.

