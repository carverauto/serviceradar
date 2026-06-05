## ADDED Requirements

### Requirement: NetFlow Map Attribution Context
The NetFlow map SHALL indicate when a displayed flow has process attribution and
SHALL provide a drilldown to the same flow detail context used by the attributed
flow explorer.

#### Scenario: Map shows attributed flow
- **GIVEN** a NetFlow map edge or flow record has linked process attribution
- **WHEN** the map renders that flow
- **THEN** the map exposes an attribution indicator without obscuring the topology
- **AND** selecting the flow shows process and collector-agent summary context

#### Scenario: Map drilldown opens details
- **GIVEN** a user selects an attributed map flow
- **WHEN** the user opens details
- **THEN** the UI navigates to or opens the shared NetFlow flow detail view
- **AND** the detail view includes process attribution, endpoint enrichment, and IOC state
