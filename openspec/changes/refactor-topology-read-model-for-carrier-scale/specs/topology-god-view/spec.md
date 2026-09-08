## ADDED Requirements

### Requirement: God-View overview uses a deterministic radial transport forest
The God-View overview SHALL construct a deterministic rooted forest from the bounded promotable topology and SHALL pass only that acyclic forest to ELK Radial. Forest roots, selected relations, relation orientation, and node order SHALL remain stable across equivalent input orderings.

#### Scenario: Cyclic topology becomes a stable overview forest
- **GIVEN** a bounded topology component contains redundant or cyclic semantic relations
- **WHEN** the overview projection is built
- **THEN** exactly one load-bearing tree path SHALL connect each non-root node to the component root
- **AND** excluded semantic relations SHALL remain identified as non-tree cross-links
- **AND** ELK Radial SHALL receive an acyclic input graph

#### Scenario: Equivalent input order preserves geometry identity
- **GIVEN** two snapshots contain identical nodes and semantic relations in different array orders
- **WHEN** their overview forests and layout cache identities are produced
- **THEN** both SHALL choose the same roots and tree relations
- **AND** both SHALL produce the same level and algorithm cache identity

### Requirement: Non-tree cross-links use bounded progressive disclosure
The overview SHALL preserve non-tree relation identity and counts without rendering every cross-link as an always-on route. A bounded focus view MAY reveal cross-links relevant to its selected component, node, or route.

#### Scenario: Overview summarizes redundant links
- **GIVEN** a component contains semantic relations excluded from its overview forest
- **WHEN** the overview renders that component
- **THEN** it SHALL expose the excluded cross-link count through component or selection metadata
- **AND** it SHALL NOT draw those relations as an always-on edge mesh

#### Scenario: Focus reveals relevant cross-links
- **GIVEN** an operator selects a bounded infrastructure neighborhood
- **WHEN** the focus level is requested
- **THEN** relevant non-tree relations SHALL retain their original semantic relation identifiers and metadata
- **AND** unrelated tenant-wide cross-links SHALL remain outside that bounded level

### Requirement: Atlas Fit always contains the current bounded level
Initial view and Fit SHALL contain every rendered glyph and route in the current bounded atlas level inside the measured safe viewport. Fixed-pixel separation constraints SHALL NOT make part of the level unreachable; the renderer SHALL reduce presentation density or change semantic level before applying a conflicting zoom floor.

#### Scenario: Fit shows the complete radial overview
- **GIVEN** a valid bounded radial overview larger than the current viewport
- **WHEN** the operator invokes Fit
- **THEN** every overview glyph and tree route SHALL be inside the safe viewport
- **AND** the camera SHALL NOT clamp above the scale required to contain that level

#### Scenario: Dense detail reduces membership before clipping
- **GIVEN** a focused endpoint neighborhood whose full member set cannot fit with self-identifying glyphs
- **WHEN** the focus level is laid out or fitted
- **THEN** the level SHALL page, sample, or aggregate members until the accepted visible set fits
- **AND** it SHALL NOT preserve an unreadable camera floor that hides part of the accepted level

### Requirement: Expanded endpoint groups are bounded focus levels
Expanding an endpoint summary SHALL enter or update a bounded focus level for that group rather than adding an unbounded member fanout to the global overview.

#### Scenario: Expansion preserves unrelated overview state
- **GIVEN** a valid overview and one expandable endpoint summary
- **WHEN** the operator expands that summary
- **THEN** the focused level SHALL retain the required anchor and transport context plus a bounded member set
- **AND** unrelated components SHALL NOT be relaid out as part of that expansion
- **AND** collapse SHALL restore the previous compatible overview scene and camera state

#### Scenario: Repeated expansion remains recoverable
- **GIVEN** the operator expands, collapses, and expands multiple endpoint groups
- **WHEN** any newly requested level fails layout or rendering
- **THEN** the last compatible good level SHALL remain visible
- **AND** the UI and server diagnostics SHALL identify the failed level, algorithm, and error reason
