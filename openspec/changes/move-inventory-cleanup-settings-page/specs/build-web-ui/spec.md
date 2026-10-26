## MODIFIED Requirements

### Requirement: Inventory Cleanup Settings
The web-ng UI SHALL expose inventory cleanup and device retention as its own Settings page,
Inventory Cleanup, at `/settings/networks/inventory-cleanup` under Network Services >
Discovery, gated by `settings.networks.manage`. The retired Sweep Profiles tab URL
`/settings/networks?tab=cleanup` SHALL redirect to that page.

#### Scenario: Configure retention window
- **GIVEN** an admin user on Settings → Network Services
- **WHEN** they open the Inventory Cleanup page
- **THEN** they can set the device deletion retention window in days
- **AND** the value is saved for the reaper job

#### Scenario: Configure reaper schedule
- **GIVEN** an admin user on the Inventory Cleanup page
- **WHEN** they update the cleanup schedule
- **THEN** the reaper job SHALL use the configured schedule

#### Scenario: Run cleanup manually
- **GIVEN** an admin user on the Inventory Cleanup page
- **WHEN** they click “Run cleanup now”
- **THEN** the reaper job SHALL execute immediately

#### Scenario: Old tab link
- **GIVEN** a bookmark or log line pointing at `/settings/networks?tab=cleanup`
- **WHEN** an admin user opens it
- **THEN** they SHALL land on the Inventory Cleanup page

## ADDED Requirements

### Requirement: Settings Search Reaches Every Settings Page
Every routed Settings page and every in-page tab a Settings LiveView handles SHALL have an
entry in the Settings catalog, and every catalog link SHALL resolve to a routed page, so the
Ctrl+K palette and the sidebar filter can reach it. CI SHALL fail when either side drifts.

#### Scenario: New Settings route without a catalog entry
- **GIVEN** a new `/settings/**` live route that is not a detail or form sub-page of an
  existing catalog view
- **WHEN** the web-ng unit tests run
- **THEN** the catalog coverage test SHALL fail and name the route

#### Scenario: Searching with words in any order
- **GIVEN** the sidebar "Search views" box or the Ctrl+K palette
- **WHEN** an operator types several words that each appear in a page's title, keywords,
  route or description
- **THEN** the page SHALL be listed regardless of word order
