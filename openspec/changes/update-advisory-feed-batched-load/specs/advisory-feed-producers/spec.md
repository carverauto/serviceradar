## MODIFIED Requirements

### Requirement: Ubuntu Normalization Is Content Addressed And Capacity Bounded

The system SHALL normalize Canonical OSV/VEX products into shared global,
CVE-independent immutable products and product sets. It SHALL derive versioned
deterministic 128-bit IDs from canonical content, retain the full SHA-256 digest
for collision validation, and SHALL fail a generation on conflicting content,
counts, references, or digests. Product-set membership SHALL use a bounded
`uuid[]` representation with indexed overlap lookup and SHALL NOT expand into a
row per statement/product membership.

#### Scenario: Repeated product set is stored once

- **GIVEN** different CVEs or evidence kinds contain the identical normalized product membership in different input orders
- **WHEN** the paired generation is loaded
- **THEN** they SHALL reference one global product-set identity independent of CVE and source order
- **AND** each OSV affected entry or VEX statement SHALL retain its own semantic assertion and provenance

#### Scenario: Product identity collision fails closed

- **GIVEN** an incoming deterministic product or product-set ID already exists
- **WHEN** its full SHA-256 digest, canonical fields, or member count differs
- **THEN** the entire paired generation SHALL fail and SHALL NOT be promoted
- **AND** no previously current advisory SHALL be withdrawn
- **AND** an advisory replaced by an earlier committed chunk of the failed run SHALL carry its complete replacement, whose assertions keep the unpromoted generation and therefore SHALL NOT read as fresh authority

#### Scenario: Capacity limits reject corpus expansion

- **GIVEN** a normalized product set exceeds 65,536 distinct products or 16 MiB of canonical projection
- **WHEN** the helper or Elixir boundary validates it
- **THEN** the paired generation SHALL fail before promotion
- **AND** the implementation SHALL NOT fall back to row-per-product expansion or silently truncate membership

#### Scenario: Version two projection keeps raw documents out of BEAM

- **GIVEN** the compact archives contain a multi-gigabyte logical OSV/VEX corpus
- **WHEN** the Go helper streams protocol version two
- **THEN** it SHALL emit bounded advisory envelopes, normalized product and product-set DTOs, and one semantic assertion DTO per OSV affected entry or VEX statement
- **AND** raw source documents and complete raw VEX product arrays SHALL neither enter the BEAM nor be stored in advisory raw JSON
- **AND** Elixir SHALL independently validate canonical PURLs, exact name-version pairs, IDs, digests, counts, and references before insertion

#### Scenario: Unchanged source object is observed without a write

- **GIVEN** a source object's modification state and normalization version match the current complete advisory
- **WHEN** the next atomic pair is consumed
- **THEN** the run SHALL record the object as observed in memory without writing any advisory, product-set, coordinate, assertion, or presence row
- **AND** a changed object SHALL replay its complete normalized replacement inside the one transaction that commits its chunk

#### Scenario: Known malformed PURL repair is exact

- **GIVEN** Canonical publishes `pkg:deb/ubuntu/<name>?arch=src?distro=<value>`, the audited family found in 280 OSV affected entries of which 32 are active
- **WHEN** the Go and Elixir boundaries normalize that PURL
- **THEN** they SHALL replace only the exact substring `?arch=src?distro=` with `?arch=src&distro=` before normal canonicalization
- **AND** they SHALL retain the raw PURL and an explicit repair flag
- **AND** every other malformed or ambiguously repaired PURL SHALL fail the paired generation

#### Scenario: Full official corpus gates persistence

- **GIVEN** fixture tests pass for the Ubuntu adapter
- **WHEN** the implementation is considered ready for scratch-database loading
- **THEN** a complete official-corpus compatibility and capacity pass SHALL first prove the measured product, set, membership, frame, memory, and disk limits
- **AND** failure of that pass SHALL block scratch loading and deployment

## ADDED Requirements

### Requirement: Advisory Feed Runs Commit In Bounded Batches

The advisory feed loader SHALL commit each chunk of changed advisories in its
own transaction, writing every advisory row together with its complete
coordinate, configuration, and assertion replacement, and SHALL NOT hold one
transaction across a whole feed run. For every provider a chunk SHALL hold at
most 2,000 records and at most 16 MiB of serialized records, except that a
single record larger than 16 MiB SHALL commit alone in its own chunk rather
than be split across transactions. It SHALL record the advisories a run
observes as an in-memory set of advisory ordinals rather than as one database
row per source object, and SHALL write nothing for an unchanged advisory. Only
after the whole run has loaded and its completeness and distinct observed count
have validated SHALL it promote the run's new advisories and withdraw the
feed's current advisories that the run did not observe, each in batches of at
most 1,000 rows that commit separately. Generation metadata SHALL be promoted only
after that.

#### Scenario: Partial failure withdraws nothing

- **GIVEN** a feed with current advisories
- **WHEN** a run fails after some of its chunks have committed
- **THEN** every previously current advisory SHALL remain current
- **AND** each advisory a committed chunk replaced SHALL carry its complete replacement and never a mix of old and new children
- **AND** no advisory first introduced by the failed run SHALL become current

#### Scenario: Complete run withdraws only absent advisories

- **GIVEN** a feed whose current advisories include some the new snapshot omits
- **WHEN** a complete run validates
- **THEN** exactly the current advisories absent from the snapshot SHALL stop being current, in batches of at most 1,000 rows
- **AND** the withdrawn advisory rows SHALL be retained for provenance

#### Scenario: Chunks are bounded by records and bytes

- **GIVEN** a run of any provider whose changed records exceed 2,000 records or 16 MiB of serialized records
- **WHEN** the loader commits them
- **THEN** no chunk transaction SHALL hold more than 2,000 records or more than 16 MiB of serialized records
- **AND** a single record larger than 16 MiB SHALL commit alone in its own chunk, whole

#### Scenario: Steady state writes nothing

- **GIVEN** a complete run over a corpus identical to the current one
- **WHEN** it completes
- **THEN** it SHALL write no advisory, coordinate, assertion, or presence row

#### Scenario: Truncated snapshot keeps the served corpus

- **GIVEN** a run whose observed advisory count is below the expected minimum or differs from its validated snapshot count
- **WHEN** the run reaches finalization
- **THEN** it SHALL NOT promote or withdraw anything
