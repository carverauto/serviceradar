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

### Requirement: On-prem sync service onboarding

Customers must be able to onboard their own on-prem sync services.

#### Scenario: On-prem sync service registers via Hello RPC

Given an on-prem sync service has valid mTLS credentials
When the sync service calls the SyncServiceHello RPC
Then a SyncService record is created with service_type=:on_prem
And the tenant_id is set from the certificate
And the sync service appears in the UI

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
