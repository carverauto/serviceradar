## ADDED Requirements

### Requirement: Integration Sources Under Network Settings

The web-ng UI SHALL display the Integrations management page as a sub-tab under Settings -> Network, alongside Sweep Profiles, Discovery, and SNMP.

#### Scenario: Navigate to Integrations via Network sub-nav
- **GIVEN** an authenticated user on the Settings page
- **WHEN** they click the "Network" tab
- **THEN** they see sub-navigation tabs: Sweep Profiles, Discovery, SNMP, Integrations
- **AND** clicking "Integrations" navigates to `/settings/networks/integrations`

#### Scenario: Integrations removed from top-level Settings tabs
- **GIVEN** an authenticated user viewing Settings
- **WHEN** they view the top-level Settings navigation
- **THEN** they do NOT see "Integrations" as a top-level tab
- **AND** they see: Cluster, Network, Agents, Events, Edge Ops, Jobs

#### Scenario: Integration CRUD routes under network path
- **GIVEN** the integration management functionality
- **THEN** the following routes SHALL be available:
  - `/settings/networks/integrations` - list all integration sources
  - `/settings/networks/integrations/new` - create new integration source
  - `/settings/networks/integrations/:id` - view integration details
  - `/settings/networks/integrations/:id/edit` - edit integration source

#### Scenario: Network tab active state includes integrations
- **GIVEN** a user on `/settings/networks/integrations`
- **WHEN** they view the Settings navigation
- **THEN** the "Network" top-level tab is highlighted as active
- **AND** the "Integrations" sub-tab is highlighted as active
