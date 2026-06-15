## ADDED Requirements

### Requirement: Partial or unchanged uploads never wipe a full inventory
Endpoint-inventory ingest SHALL NOT replace a device's current package set with a smaller set unless the incoming scan is a full, successful scan carrying the package list. An `unchanged` (hash-gated, SBOM-omitted) upload with no prior `current` scan SHALL NOT explode to zero rows; the ingestor SHALL either request a full upload or rehydrate rows from the stored SBOM artifact blob. Promotion of a new current set SHALL NOT demote a prior larger full inventory to zero on a partial/validation upload.

#### Scenario: Unchanged upload with no prior current scan
- **WHEN** an `unchanged` upload arrives with a reported `package_count` but no SBOM and there is no prior `current` scan for the device
- **THEN** the ingestor does not write zero current rows while stamping the reported count; it requests a full scan or rehydrates from the artifact blob

#### Scenario: Partial scan must not wipe full inventory
- **WHEN** a successful-but-partial scan with fewer packages is ingested after a full scan
- **THEN** the prior full current inventory is not wholesale-replaced by the smaller set

### Requirement: Scan package count is consistent with stored rows
The scan `package_count` surfaced to operators SHALL be reconciled against the number of exploded `current` package rows (or the reported and loaded counts SHALL be stored and labeled distinctly), so the scan summary cannot silently claim a count that the stored rows do not back.

#### Scenario: Reported count diverges from loaded rows
- **WHEN** a scan reports N packages but only M current rows are stored
- **THEN** the divergence is reconciled or explicitly flagged at ingest, not only surfaced as a UI warning
