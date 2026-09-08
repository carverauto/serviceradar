## MODIFIED Requirements
### Requirement: Camera Plugin Source Acquisition
The edge camera plugin architecture SHALL support vendor media source acquisition for both plaintext RTSP and RTSP-over-TLS sources without changing the existing relay session contract between the agent, gateway, and core media plane.

#### Scenario: Vendor exposes plaintext RTSP
- **WHEN** a camera plugin resolves a plaintext RTSP source
- **THEN** the agent acquires media through the existing source acquisition path and uploads it through the current relay session contract

#### Scenario: Vendor exposes RTSP over TLS
- **WHEN** a camera plugin resolves an RTSP-over-TLS source
- **THEN** the agent acquires media through a TLS-capable source acquisition path and uploads it through the current relay session contract
