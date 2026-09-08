## ADDED Requirements

### Requirement: Scanner Add-On Inventory Diagnostics
The agent SHALL carry source/plugin-level scanner add-on diagnostics in scan status and upload metadata without depending on a specific scanner implementation.

#### Scenario: Complete package source scan reports source count
- **GIVEN** a scanner add-on enables OS package collection on a host
- **WHEN** a package source or extractor completes successfully
- **THEN** the scan diagnostics SHALL include that source/plugin as detected and enabled
- **AND** it SHALL include package count and success state

#### Scenario: Missing package source reports skipped reason
- **GIVEN** a scanner add-on enables OS package collection on a host without an applicable package source
- **WHEN** that source/plugin is attempted or evaluated
- **THEN** the scan diagnostics SHALL include the source/plugin as skipped or unavailable
- **AND** the skipped reason SHALL distinguish missing binary, missing database, disabled source, and unsupported platform where applicable

#### Scenario: Permission failure reports partial state
- **GIVEN** a scanner add-on cannot read a configured package database or target path because of file permissions
- **WHEN** the scanner completes the scan
- **THEN** the scan diagnostics SHALL include a permission-denied error for that source
- **AND** the scan SHALL be marked partial rather than successful-complete

#### Scenario: Output bounds report truncation
- **GIVEN** a scanner add-on reaches max package count or max output bytes
- **WHEN** it produces scan metadata
- **THEN** diagnostics SHALL record the truncation reason
- **AND** ingest SHALL preserve that the package list is partial

### Requirement: Scanner Diagnostics Remain Bounded
Scanner add-on diagnostics SHALL be structured and bounded so status and ingest payloads cannot grow with every package row or finding.

#### Scenario: Diagnostics omit package row details
- **GIVEN** a host has thousands of installed packages
- **WHEN** a scanner add-on emits diagnostics
- **THEN** diagnostics SHALL contain source summaries and error summaries only
- **AND** full package rows SHALL remain in the normal bounded inventory artifact path

#### Scenario: Older agents remain compatible
- **GIVEN** an older agent reports endpoint inventory without source/plugin-level diagnostics
- **WHEN** the server ingests the report
- **THEN** the server SHALL treat diagnostic coverage as unknown
- **AND** it SHALL NOT mark low package counts as complete solely from missing diagnostics
