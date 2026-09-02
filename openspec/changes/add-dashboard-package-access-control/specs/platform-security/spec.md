## ADDED Requirements

### Requirement: Permission catalog declares presentation metadata

Every entry in the RBAC permission catalog SHALL declare its `section`, its `resource`, and its
`action` explicitly. The Policy Editor SHALL use those declared values to place a permission in the
grid. It MUST NOT infer a permission's resource or action by splitting the permission key on `.`,
so that a permission key and the place it is presented are independent and a key can be grouped with
its peers without being renamed.

#### Scenario: Key namespace and section may differ
- **GIVEN** a catalog entry whose key namespace does not match its section, such as a
  `cli.dashboard.publish` key declared under the `dashboards` section
- **WHEN** the Policy Editor renders that section
- **THEN** the permission SHALL appear under its declared resource column with its declared action
  row
- **AND** the column header SHALL be the declared human-readable resource label, never the raw
  permission key

#### Scenario: Permissions from different namespaces share one section
- **GIVEN** the `analytics.dashboards.*` keys declare the `dashboards` section
- **AND** the `dashboards.packages.*` keys declare the `dashboards` section
- **WHEN** an administrator opens the Dashboards section of the Policy Editor
- **THEN** both sets SHALL be visible on that one section as separate resource columns
- **AND** the underlying permission keys SHALL be unchanged

#### Scenario: A catalog entry missing metadata fails the build
- **WHEN** the catalog is compiled with an entry that omits `section`, `resource`, or `action`
- **THEN** the build SHALL fail rather than fall back to key-splitting

#### Scenario: Keys that are not dot-separated still render
- **GIVEN** catalog keys that use a separator other than `.`, such as `visibility_profiles:read`
- **WHEN** the Policy Editor renders their section
- **THEN** each SHALL appear under its declared resource column and declared action row
- **AND** no action row with an empty label SHALL be rendered

### Requirement: Policy Editor renders action rows per section

The Policy Editor SHALL render, for the active section, only the action rows that section's
permissions actually declare. It MUST NOT render the union of every action in the catalog against
every section. Rows SHALL be ordered by a canonical action vocabulary first and by the section's
declaration order for actions outside that vocabulary, so common CRUD verbs stay aligned across
sections while section-specific verbs remain visible rather than sorted to the bottom.

#### Scenario: A small section renders a small grid
- **GIVEN** a section whose permissions declare only the actions `publish`, `enable`, and `disable`
- **WHEN** an administrator opens that section
- **THEN** the grid SHALL render exactly three action rows
- **AND** SHALL NOT render blank rows for actions belonging to other sections

#### Scenario: Section-specific actions are not buried
- **GIVEN** a section whose actions are outside the canonical CRUD vocabulary
- **WHEN** the section renders
- **THEN** its actions SHALL appear in the section's declared order
- **AND** SHALL NOT be pushed below unrelated actions

#### Scenario: Common verbs stay aligned across sections
- **GIVEN** two sections that both declare `view` and `delete`
- **WHEN** an administrator switches between them
- **THEN** `view` SHALL precede `delete` in both

### Requirement: Permission key aliases

The RBAC resolver SHALL support declaring one permission key as an alias of another. An actor
holding either key SHALL satisfy a check written against either key, in both directions. Aliased
keys SHALL be presented once in the Policy Editor, under the canonical name, and toggling the
canonical entry SHALL be sufficient to satisfy code that still names the deprecated key.

#### Scenario: Deprecated key still satisfies a check
- **GIVEN** `cli.dashboard.publish` is declared an alias of `dashboards.packages.publish`
- **AND** a role profile that holds only `cli.dashboard.publish`
- **WHEN** code checks for `dashboards.packages.publish`
- **THEN** the check SHALL pass

#### Scenario: Canonical key satisfies a legacy call site
- **GIVEN** a role profile that holds only `dashboards.packages.publish`
- **WHEN** an existing hardcoded call site checks for `cli.dashboard.publish`
- **THEN** the check SHALL pass

#### Scenario: Aliases do not duplicate the grid
- **WHEN** an administrator opens a section containing an aliased pair
- **THEN** exactly one checkbox SHALL be rendered for that pair, under the canonical name

#### Scenario: Existing role profiles need no rewrite
- **WHEN** a deployment upgrades to a release that introduces an alias
- **THEN** no stored role-profile permission list SHALL require modification
- **AND** no profile SHALL gain or lose an effective capability as a result of the alias

### Requirement: Permissions absent from the catalog remain visible to administrators

A permission present on a role profile but absent from the catalog SHALL continue to be surfaced to
administrators as an unmapped permission rather than silently dropped, so that a catalog metadata
omission is detectable from the Policy Editor.

#### Scenario: Unmapped permission is surfaced
- **GIVEN** a role profile holding a permission key the catalog no longer describes
- **WHEN** an administrator opens that profile in the Policy Editor
- **THEN** the key SHALL be listed as an unmapped permission
- **AND** it SHALL remain on the profile until an administrator removes it
