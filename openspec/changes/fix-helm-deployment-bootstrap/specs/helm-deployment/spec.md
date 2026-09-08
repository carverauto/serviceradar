# Helm Deployment

This capability defines requirements for one-command Helm deployments.

## ADDED Requirements

### Requirement: CNPG TLS CA certificate is trusted by all database clients

All services that connect to CNPG MUST mount the cluster's CA certificate and configure their TLS clients to trust it.

#### Scenario: SPIRE server connects to CNPG with TLS verification

- **Given** the SPIRE server is deployed with PostgreSQL datastore
- **When** SPIRE server attempts to connect to CNPG
- **Then** the connection succeeds with TLS verification
- **And** no x509 certificate errors appear in logs

#### Scenario: db-event-writer connects to CNPG with TLS verification

- **Given** db-event-writer is deployed with CNPG configuration
- **When** db-event-writer attempts to insert batch messages
- **Then** the connection succeeds with TLS verification
- **And** no x509 certificate errors appear in logs

---

### Requirement: Oban tables are created in the application schema

Oban job tables MUST be created in the same schema used by the application's search_path, not in the public schema.

#### Scenario: Migration creates Oban tables in configured schema

- **Given** the database user has search_path set to `platform,ag_catalog`
- **When** the Oban migration runs
- **Then** `oban_jobs` and `oban_peers` tables are created in the `platform` schema
- **And** the application can query Oban tables without explicit schema prefix

#### Scenario: Core-elx queries Oban tables successfully

- **Given** Oban tables exist in the `platform` schema
- **When** core-elx starts and schedules jobs
- **Then** no "relation oban_jobs does not exist" errors occur
- **And** Oban workers execute successfully

---

### Requirement: Horde process names are unique across the supervision tree

Elixir applications using Horde MUST use unique process names that don't conflict with Horde's internal naming conventions.

#### Scenario: Core-elx Horde supervisor starts without naming conflict

- **Given** core-elx defines a ProcessRegistry with DynamicSupervisor
- **When** the application starts
- **Then** the supervisor starts successfully
- **And** no "already started" errors occur

#### Scenario: Web-ng Horde supervisor starts without naming conflict

- **Given** web-ng defines a ProcessRegistry with DynamicSupervisor
- **When** the application starts
- **Then** the supervisor starts successfully
- **And** no "already started" errors occur

---

### Requirement: Fresh Helm install brings up all services without intervention

A single `helm install` command MUST deploy and start all services successfully.

#### Scenario: Fresh namespace deployment

- **Given** a clean Kubernetes namespace with no prior ServiceRadar installation
- **When** running `helm install serviceradar ./helm/serviceradar -n <namespace> --create-namespace`
- **Then** all pods reach Running state within 5 minutes
- **And** no manual intervention is required
- **And** no CrashLoopBackOff conditions occur

#### Scenario: All services pass health checks

- **Given** ServiceRadar is installed via Helm
- **When** all init jobs complete
- **Then** CNPG cluster is 3/3 healthy
- **And** SPIRE server is 2/2 healthy
- **And** core-elx is 1/1 healthy
- **And** web-ng is 1/1 healthy
- **And** all other services are Running
