## ADDED Requirements

### Requirement: Core-ELX boombox relay capture files use secure temporary allocation
Core-ELX SHALL stage relay-derived boombox capture files through secure temporary allocation rather than predictable filenames in the global temp directory.

#### Scenario: External boombox worker stages a relay payload
- **GIVEN** the external boombox worker receives a bounded H264 relay payload for analysis
- **WHEN** it stages the payload for boombox decoding
- **THEN** it allocates the capture file through a secure random temp path
- **AND** it removes the staged file after decoding completes

#### Scenario: Relay-attached boombox sidecar allocates its default capture path
- **GIVEN** the boombox sidecar starts without an explicit `output_path`
- **WHEN** it allocates a capture file for the first keyframe payload
- **THEN** the output path is created through the shared secure temp allocation helper
- **AND** the capture file is cleaned up when the sidecar closes
