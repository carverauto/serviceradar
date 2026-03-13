# Pitch Deck Update Specification

## Purpose
The ServiceRadar pitch deck MUST communicate the platform's ability to bridge the gap between fragmented network/security/observability silos and deliver a unified, causal, and high-fidelity visibility fabric for heterogeneous enterprise networks.

## Requirements

### Requirement: Unified Fabric Narrative
The pitch deck SHALL articulate a clear shift from fragmented legacy monitoring (siloed NCM, SIEM, PRTG, Nagios) to the ServiceRadar Unified Fabric.

#### Scenario: Silo-to-Fabric Transition
- **GIVEN** a potential investor reviews the deck
- **WHEN** they reach the "Market Opportunity" and "Value Proposition" sections
- **THEN** they see a clear comparison showing legacy tools (Solarwinds, PRTG, Nagios) as fragmented silos
- **AND** ServiceRadar as the unified, cross-protocol, causal fabric that bridges them

### Requirement: FabricView Topology High-Fidelity Representation
The deck MUST represent "FabricView" not just as a map, but as a backend-authoritative, high-fidelity graph built from multi-protocol evidence (LLDP/CDP/SNMP/UniFi).

#### Scenario: Topology Presentation
- **GIVEN** the "Technology" or "Topology" slide
- **WHEN** it is presented
- **THEN** it highlights the transition to Apache AGE-backed authoritative topology
- **AND** it mentions the removal of frontend-side inference for professional-grade stability

### Requirement: Extensible Edge with WASM Plugins
The deck SHALL describe the ServiceRadar agent as an "Extensible Edge Engine" using the wazero WASI runtime for sandboxed plugins.

#### Scenario: Plugin Ecosystem Value
- **GIVEN** the "Extensibility" slide
- **WHEN** it describes the plugin system
- **THEN** it emphasizes security (sandboxing), performance (WASM), and the Plugin SDK
- **AND** it specifically mentions support for specialized IoT/IPTV camera management (e.g., 6,000+ Axis targets)

### Requirement: Advanced WiFi Site Survey & Signal Mapping
The deck MUST showcase the advanced WiFi site survey and signal mapping capabilities using ARKit, Log-Distance Path Loss models, and 3D volumetric rendering.

#### Scenario: WiFi Survey Presentation
- **GIVEN** the "Vertical Offerings" or "WiFi" slide
- **WHEN** it is presented
- **THEN** it highlights the use of ARKit for first-person signal tracking
- **AND** it mentions the "Invisible RF Space" volumetric rendering and spatial convergence models

### Requirement: Causal Security Context with Deepcausality
The deck SHALL introduce the concept of "Causal Security Context" powered by the `deep_causality` engine.

#### Scenario: Causal Engine Value
- **GIVEN** the "Security" or "Causal Fabric" slide
- **WHEN** it describes the system's security posture
- **THEN** it highlights the temporal context hypergraph for identifying unusual patterns
- **AND** it explains how ServiceRadar manages security context across the entire heterogeneous network fabric

### Requirement: Enterprise Positioning against Incumbents
The deck MUST explicitly position ServiceRadar as a modern, superior alternative to incumbents like OpenText Network Node Manager, PRTG, Solarwinds, and Nagios.

#### Scenario: Competitive Analysis
- **GIVEN** the "Competitive Landscape" slide
- **WHEN** it is reviewed
- **THEN** it lists incumbents (PRTG, Solarwinds, Nagios)
- **AND** it shows ServiceRadar as having superior edge resilience, topology accuracy, and unified causal context

### Requirement: Tooling Upgrade
The pitch deck system SHALL be upgraded to Slidev v52.14.1+ to leverage improved rendering and the new overview/presenter features.

#### Scenario: Data Stack Presentation
- **GIVEN** the "Technology" or "Architecture" slide
- **WHEN** it is presented
- **THEN** it highlights the transition from fragmented or specialized engines to a unified Postgres stack
- **AND** it specifically mentions Apache AGE (Graph), TimescaleDB (Time-series), PostGIS (Spatial), pgvector (AI/Vector), and ParadeDB (Search/Analytics)
