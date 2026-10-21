## ADDED Requirements

### Requirement: Plugins are listed as logical plugins, not package versions

The plugin management UI SHALL list one row per logical plugin (`plugin_id`).

Each row SHALL show:
- the plugin name;
- the versions currently assigned;
- the latest approved version;
- whether a newer version is available or awaiting review;
- the update-policy mix of its owners;
- assignment counts, including how many are behind the latest approved version;
- a health rollup.

Individual package versions SHALL be reachable from the plugin's detail view.
They SHALL NOT be listed as separate rows on the main page.

#### Scenario: Several versions of one plugin
- **WHEN** a plugin has five imported versions, two of them approved
- **THEN** the Installed view shows a single row for that plugin
- **AND** the row names the latest approved version and the versions in use

#### Scenario: No silent truncation
- **WHEN** more plugins exist than fit on one page
- **THEN** the list paginates on the server and every plugin is reachable

### Requirement: Plugin detail groups assignments by owner

The plugin detail view SHALL group assignments by owner: manual assignment,
target policy and credential rule.

For each assignment it SHALL show:
- the agent;
- the assigned version;
- the update policy;
- the owner status;
- a link to the owning rule or policy.

Choosing a version other than the latest approved SHALL require a deliberate
pin action.

#### Scenario: Credential-rule assignment
- **WHEN** an assignment is materialized by a credential rule
- **THEN** the detail view labels it with that rule and links to it
- **AND** shows that it tracks the latest approved version

#### Scenario: Pinning a version
- **WHEN** an operator selects an older approved version for an assignment
- **THEN** the assignment is pinned to that version and stops tracking latest

### Requirement: Separate views for installed plugins, pending updates and the catalog

The plugin management UI SHALL provide three separate views:
- **Installed** plugins;
- **Updates** awaiting review, each showing its requested-grant diff against
  the approved grant;
- **Catalog**, holding repositories, releases, import, synchronization status
  and the verification policy.

Capacity reporting SHALL NOT occupy the main plugins view.

#### Scenario: Reviewing a widened update
- **WHEN** a new version requests an allowed network the approved grant lacks
- **THEN** the Updates view lists it with that network marked as added
- **AND** offers approve and deny

### Requirement: Fleet upgrade to latest

The UI SHALL offer an "Upgrade to latest" action for one plugin and for all
plugins. Before executing, it SHALL preview the selected pinned owners grouped
as:
- compatible;
- incompatible;
- unavailable;
- already current.

Executing the action SHALL start rollouts rather than updating assignment rows
directly.

#### Scenario: Upgrading a plugin fleet
- **WHEN** an operator runs "Upgrade to latest" for a plugin with ten pinned assignments, two of them on unavailable agents
- **THEN** the preview shows eight compatible and two unavailable
- **AND** confirming starts a rollout for the eight

### Requirement: Plugin management pages load without blocking work

Plugin management LiveViews SHALL NOT perform database or remote repository
calls during the disconnected mount. They SHALL NOT perform remote repository
calls synchronously in the LiveView process.

#### Scenario: Catalog fetch
- **WHEN** the Catalog view loads release listings from a remote repository
- **THEN** the fetch runs asynchronously and the page renders a loading state until it completes
