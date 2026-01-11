# Capability: Platform Bootstrap

Platform bootstrap handles automatic first-install initialization of the ServiceRadar platform, including default tenant creation, admin user provisioning, and secure credential storage.

## ADDED Requirements

### Requirement: First-Install Detection

The system SHALL detect first-install state by querying for the existence of the default tenant and admin user in the database.

#### Scenario: Fresh installation detected

- **WHEN** the core-elx application starts
- **AND** no tenant with slug "default" exists in the database
- **THEN** the system SHALL proceed with platform bootstrap
- **AND** log "[PLATFORM BOOTSTRAP] First install detected, initializing platform..."

#### Scenario: Existing installation detected

- **WHEN** the core-elx application starts
- **AND** a tenant with slug "default" already exists
- **AND** an admin user exists in that tenant
- **THEN** the system SHALL skip bootstrap
- **AND** log "[PLATFORM BOOTSTRAP] Platform already initialized, skipping bootstrap"

#### Scenario: Partial installation detected

- **WHEN** the core-elx application starts
- **AND** a tenant with slug "default" exists
- **AND** no admin user exists in that tenant
- **THEN** the system SHALL create the admin user
- **AND** generate and store credentials
- **AND** log "[PLATFORM BOOTSTRAP] Admin user created for existing tenant"

### Requirement: Default Tenant Creation

The system SHALL create a default tenant on first install with well-known attributes for compatibility with existing configurations.

#### Scenario: Default tenant created

- **WHEN** first-install is detected
- **THEN** the system SHALL create a tenant with:
  - ID: `00000000-0000-0000-0000-000000000000`
  - Name: "Default Organization"
  - Slug: "default"
  - Status: `:active`
  - Plan: `:free`

#### Scenario: Tenant creation failure handled

- **WHEN** tenant creation fails due to database error
- **THEN** the system SHALL log the error
- **AND** retry after 30 seconds
- **AND** NOT proceed with admin user creation

### Requirement: Admin User Creation

The system SHALL create a super_admin user in the default tenant with a cryptographically secure random password.

#### Scenario: Admin user created with random password

- **WHEN** first-install is detected
- **AND** default tenant exists or is created
- **THEN** the system SHALL create a user with:
  - Email: value of `PLATFORM_ADMIN_EMAIL` env var (default: `admin@serviceradar.local`)
  - Role: `:super_admin`
  - Tenant: default tenant
  - Password: 24-character random string

#### Scenario: Admin email configurable

- **WHEN** `PLATFORM_ADMIN_EMAIL` environment variable is set
- **THEN** the system SHALL use that value for the admin email
- **WHEN** `PLATFORM_ADMIN_EMAIL` is not set
- **THEN** the system SHALL use `admin@serviceradar.local`

#### Scenario: Tenant membership created

- **WHEN** admin user is created
- **THEN** the system SHALL create a TenantMembership with:
  - Role: `:owner`
  - User: the created admin user
  - Tenant: the default tenant

### Requirement: First User Promotion

The system SHALL promote the first user created in a fresh install to platform owner with super_admin privileges.

#### Scenario: First user becomes platform owner

- **WHEN** a user is created and no other users exist
- **AND** a platform tenant exists (`is_platform_tenant: true`)
- **THEN** the user SHALL be created with role `:super_admin`
- **AND** the platform tenant SHALL be updated with `owner_id` set to that user
- **AND** an owner TenantMembership SHALL be created for the platform tenant

### Requirement: Secure Password Generation

The system SHALL generate cryptographically secure passwords using a strong random source.

#### Scenario: Password meets security requirements

- **WHEN** a password is generated
- **THEN** the password SHALL be 24 characters long
- **AND** include uppercase letters (A-Z)
- **AND** include lowercase letters (a-z)
- **AND** include digits (0-9)
- **AND** include symbols (!@#$%^&*)
- **AND** use `:crypto.strong_rand_bytes/1` as entropy source

#### Scenario: Password never reused

- **WHEN** bootstrap runs multiple times (e.g., dev testing)
- **THEN** each generated password SHALL be unique

### Requirement: Credential Storage

The system SHALL persist generated credentials to deployment-appropriate storage for operator retrieval.

#### Scenario: Docker Compose credential storage

- **WHEN** running in Docker Compose mode
- **AND** `/var/run/secrets/kubernetes.io/serviceaccount/token` does not exist
- **THEN** the system SHALL write credentials to `/data/platform/admin-credentials.json`
- **AND** set file permissions to `0600`
- **AND** include `email`, `password`, and `created_at` fields

#### Scenario: Kubernetes credential storage

- **WHEN** running in Kubernetes mode
- **AND** `/var/run/secrets/kubernetes.io/serviceaccount/token` exists
- **THEN** the system SHALL create/update Secret `serviceradar-admin-credentials`
- **AND** include `email`, `password`, and `created_at` data keys
- **AND** use the same namespace as the core-elx pod

#### Scenario: Storage failure fallback

- **WHEN** Kubernetes Secret creation fails
- **THEN** the system SHALL fall back to file-based storage
- **AND** log a warning about the fallback

### Requirement: Console Credential Display

The system SHALL display generated credentials to the console on first install only.

#### Scenario: Credentials displayed on first install

- **WHEN** admin user is created for the first time
- **THEN** the system SHALL log to console:
  ```
  ==========================================
  PLATFORM BOOTSTRAP COMPLETE
  ==========================================
  Admin Email: admin@serviceradar.local
  Admin Password: <generated-password>

  Save these credentials securely.
  Change the password after first login.
  ==========================================
  ```

#### Scenario: Credentials not displayed on restart

- **WHEN** the application restarts
- **AND** admin user already exists
- **THEN** the system SHALL NOT log any credentials
- **AND** only log "[PLATFORM BOOTSTRAP] Platform already initialized"

### Requirement: Bootstrap Order in Supervision Tree

The system SHALL ensure Platform Bootstrap runs before NATS Operator Bootstrap.

#### Scenario: Tenant exists before NATS provisioning

- **WHEN** the application supervision tree starts
- **THEN** `Platform.Bootstrap` SHALL start before `NATS.OperatorBootstrap`
- **AND** default tenant SHALL exist before NATS account provisioning attempts

#### Scenario: NATS account created for bootstrapped tenant

- **WHEN** Platform Bootstrap completes successfully
- **AND** NATS Operator Bootstrap runs
- **THEN** NATS account SHALL be provisioned for the default tenant
- **AND** log "[NATS Bootstrap] Creating NATS account for tenant: default"

### Requirement: Idempotent Bootstrap

The system SHALL be safe to run multiple times without side effects.

#### Scenario: Restart does not duplicate resources

- **WHEN** the application restarts after successful bootstrap
- **THEN** no duplicate tenants SHALL be created
- **AND** no duplicate users SHALL be created
- **AND** no duplicate credentials SHALL be stored
- **AND** the existing password SHALL NOT be changed

#### Scenario: Multiple replicas handle race condition

- **WHEN** multiple core-elx replicas start simultaneously
- **AND** both attempt bootstrap
- **THEN** only one SHALL succeed in creating resources
- **AND** the other SHALL detect existing resources and skip
- **AND** no errors SHALL be logged for the constraint violation
