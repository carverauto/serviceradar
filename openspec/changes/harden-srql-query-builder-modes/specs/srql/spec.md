## ADDED Requirements

### Requirement: SRQL query modes for builder composition
The system SHALL treat SRQL queries as belonging to a query mode that determines which filter fields are valid when the web-ng query builder composes a query.

The visual builder SHALL represent these modes:

- **row** - no `bucket:` control token
- **downsample** - `bucket:` present (chart / time-bucket path)

This requirement applies only to visual-builder composition. A query containing `stats:` SHALL remain on the freeform/desynchronized path unless a later change adds explicit stats state and a verified stats filter allowlist; it SHALL NOT be normalized as a row query.

#### Scenario: Downsample mode detected from builder state
- **WHEN** the query builder state has a non-empty `bucket` value for an entity with downsample enabled
- **THEN** the active mode is **downsample**

#### Scenario: Row mode when chart knobs are cleared
- **WHEN** the query builder state has an empty `bucket` and no stats expression
- **THEN** the active mode is **row**

#### Scenario: Stats query remains outside builder composition
- **GIVEN** a raw SRQL query containing `stats:`
- **WHEN** the page attempts to synchronize it with visual-builder state
- **THEN** the raw query remains unchanged
- **AND** the builder may be marked unsupported and desynchronized instead of applying row or downsample normalization

### Requirement: Mode-aware filter allowlists in the catalog
The SRQL entity catalog SHALL expose filter field lists suitable for row and downsample builder composition for `flows`, which participates in multiple engine paths.

For an entity with `downsample: true`, the catalog SHALL provide a downsample filter allowlist that is a projection of fields the downsample engine path accepts (not a superset of unimplementable fields).

#### Scenario: Flows chart filter list excludes known-illegal fields
- **GIVEN** entity `flows` with downsample enabled
- **WHEN** the builder is in downsample mode
- **THEN** the filter field choices SHALL NOT include fields that the downsample engine path rejects (for example `tag`, `near`, and geo country fields, until those paths support them)

#### Scenario: Flows row filter list remains broader
- **GIVEN** entity `flows`
- **WHEN** the builder is in row mode
- **THEN** the filter field choices MAY include row-path fields such as `tag`, `near`, and country filters that are valid for non-bucket queries

### Requirement: Builder only offers legal filters for the active mode
While the query builder is in sync with the draft query, the filter field selector SHALL only offer fields allowed for the active mode of the current entity.

#### Scenario: User cannot pick a chart-illegal filter in the dropdown
- **GIVEN** a flows query with `bucket:5m` active in the builder
- **WHEN** the user opens the filter field dropdown
- **THEN** chart-illegal fields are not selectable options

### Requirement: Mode transition strips illegal filters with user-visible notice
When the builder transitions into a stricter mode (for example enabling `bucket`), it SHALL remove filters whose fields are not allowed in the new mode and SHALL inform the user that filters were removed.

#### Scenario: Enabling chart mode drops tag filter
- **GIVEN** a flows builder state in row mode with a filter on `tag`
- **WHEN** the user sets a non-empty bucket (chart mode)
- **THEN** the `tag` filter is removed from builder state
- **AND** the user is shown a notice that at least one filter was removed because it is unavailable in chart mode

#### Scenario: Leaving chart mode retains remaining filters
- **GIVEN** a flows builder state in downsample mode with a legal `app` filter
- **WHEN** the user clears the bucket
- **THEN** the `app` filter remains

### Requirement: Builder-composed filter fields remain valid for the selected engine path
When the builder is supported and in sync, applying or rebuilding the draft query SHALL NOT introduce filter fields that are invalid for the active mode. This requirement covers field availability; a mode-specific filter-operator capability matrix is deferred.

#### Scenario: Builder rebuild with chart + cidr is well-formed
- **GIVEN** flows downsample mode and a `cidr` filter (supported by the downsample engine)
- **WHEN** the builder builds the query string
- **THEN** the query includes `bucket:` and `cidr:` (or equivalent) without requiring manual removal of chart tokens

#### Scenario: Builder rebuild never emits chart + tag after normalize
- **GIVEN** flows builder state that somehow contains both a non-empty bucket and a `tag` filter
- **WHEN** the builder normalizes state and builds the query
- **THEN** the built query does not include a `tag:` clause while `bucket:` remains set
  (either the tag is stripped or the mode is adjusted according to product rules; default is strip tag and keep bucket)

### Requirement: Freeform SRQL remains a superset path
The system SHALL continue to allow users to type SRQL that the builder cannot represent losslessly. This includes both unparseable syntax and otherwise parseable queries whose clauses conflict with the active builder mode. Such queries SHALL disable builder sync rather than silently rewriting freeform text.

#### Scenario: Unparseable freeform does not force strip rewrite
- **GIVEN** a freeform SRQL string the builder cannot parse
- **WHEN** the user edits the text bar without using the builder
- **THEN** the system does not rewrite the bar solely to enforce mode filter allowlists
- **AND** builder sync may be marked false until the query is parseable again

#### Scenario: Parseable mode conflict does not silently lose a raw filter
- **GIVEN** a freeform flows query containing both a non-empty `bucket:` and a row-only `tag:` filter
- **WHEN** the page attempts to synchronize visual-builder state
- **THEN** the raw query and draft remain unchanged
- **AND** builder support and sync are marked false instead of accepting normalized state without the `tag:` clause

#### Scenario: Freeform stats query is preserved
- **GIVEN** a freeform SRQL string containing `stats:` that the visual builder does not model
- **WHEN** the page attempts to synchronize builder state
- **THEN** the raw query remains unchanged
- **AND** builder sync is marked false rather than applying row-mode normalization

### Requirement: Query Builder Integration
The SRQL query builder UI SHALL allow users to add multiple filter rows. Each row becomes one clause in the final query. All rows SHALL be joined with whitespace (implicit AND).

The builder SHALL compose only filter fields that are valid for the active query mode of the selected entity. Filter stacking remains implicit AND for all emitted clauses.

Example UI configuration (row mode):
- Field: discovery_sources, Operator: contains, Value: armis
- Field: hostname, Operator: starts_with, Value: srv-

Produces: `in:devices discovery_sources:armis hostname:srv-%`

#### Scenario: Multiple filters stack with AND
- **WHEN** the user adds two filter rows in the builder
- **THEN** the built query contains both clauses separated by whitespace (implicit AND)

#### Scenario: Chart mode filters remain stacked with AND
- **GIVEN** downsample mode with two legal filters
- **WHEN** the builder builds the query
- **THEN** both filter clauses appear with implicit AND after downsample control tokens
