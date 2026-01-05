# Sync Service Onboarding

## ADDED Requirements

### Requirement: SaaS sync service auto-onboarding

The platform must automatically onboard a SaaS sync service during platform bootstrap.

#### Scenario: Platform bootstrap creates SaaS sync service

Given the platform is starting for the first time
When the bootstrap process runs
Then a SyncService record is created with is_platform_sync=true
And the service_type is set to :saas
And all tenants have access to this sync service

#### Scenario: Platform bootstrap writes minimal sync config
Given the platform is starting for the first time
When the bootstrap process runs
Then a minimal sync config file is generated for the platform sync service
And the config includes only identity, gateway address, and TLS paths required to boot
And integration configuration is omitted from the file

### Requirement: On-prem sync service onboarding

Customers must be able to onboard their own on-prem sync services.

#### Scenario: On-prem sync service registers via Hello RPC

Given an on-prem sync service has valid mTLS credentials
When the sync service calls the AgentGatewayService.Hello RPC
Then a SyncService record is created with service_type=:on_prem
And the tenant_id is set from the certificate
And the sync service appears in the UI

#### Scenario: Edge onboarding generates minimal sync config
Given a tenant user initiates edge onboarding for sync
When the onboarding package is generated
Then the package includes a minimal sync config file
And the config contains only identity, gateway address, and TLS paths required to boot
And the sync service fetches full configuration via GetConfig after startup

#### Scenario: Sync service heartbeat tracking

Given an onboarded sync service
When the sync service sends a heartbeat
Then the last_heartbeat_at timestamp is updated
And the status changes to :online if previously offline

### Requirement: Sync service status tracking

The system must track sync service availability based on heartbeats.

#### Scenario: Sync service goes offline

Given a sync service with last_heartbeat_at older than 2 minutes
When the status is computed
Then the status is :offline

#### Scenario: Sync service is online

Given a sync service with last_heartbeat_at within the last 2 minutes
When the status is computed
Then the status is :online

## ADDED Requirements

### Requirement: Integration source sync service assignment

The system MUST require integration sources to be assigned to a specific sync service.

#### Scenario: Creating integration with sync service

Given at least one sync service is available
When the user creates a new integration source
Then the user must select which sync service processes the integration
And the integration is saved with sync_service_id

#### Scenario: Integration sources gated on sync availability

Given no sync services are onboarded for a tenant
When the user views the integrations page
Then the "Add Integration" button is disabled
And a message explains that a sync service must be onboarded first

### Requirement: Edge sync onboarding entrypoint
The integrations UI MUST provide an explicit action to onboard an edge sync service.

#### Scenario: Integrations UI exposes edge sync onboarding
Given a user is viewing the integrations page
When they look below the "+ New Source" action
Then an "Add Edge Sync Service" button is visible
And the button starts the edge sync onboarding flow
