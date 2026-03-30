## ADDED Requirements
### Requirement: Edge Site Bundles Use Secure Temporary Archive Handling
The system SHALL generate edge-site deployment tarballs using secure temporary file handling and SHALL NOT rely on predictable filenames in a shared temporary directory.

#### Scenario: Edge-site tarball staging uses secure tempfiles
- **GIVEN** an operator requests an edge-site deployment bundle
- **WHEN** the bundle archive is created
- **THEN** the system SHALL use secure temporary file handling for the archive
- **AND** it SHALL remove the staged archive after reading it back
