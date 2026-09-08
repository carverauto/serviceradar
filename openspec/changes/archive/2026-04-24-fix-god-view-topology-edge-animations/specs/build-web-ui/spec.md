## ADDED Requirements
### Requirement: God-View edge activity animations remain visually detectable
The God-View topology renderer SHALL display animated edge particles as visually distinct moving markers so operators can detect edge activity at normal zoom levels.

#### Scenario: Particles are visible against base topology edges
- **GIVEN** a God-View topology with active edges and particle animation enabled
- **WHEN** the topology view is rendered
- **THEN** animated particles are visually distinguishable from the static edge stroke
- **AND** particle contrast is sufficient to avoid blending into the edge color.

#### Scenario: Particle layer is not occluded by static edge layer
- **GIVEN** the deck.gl topology view with both static edges and animated particles
- **WHEN** layers are composed for rendering
- **THEN** particle markers render above or otherwise remain visible relative to static edge lines
- **AND** particles are not fully hidden by line-layer depth/order settings.

#### Scenario: Reduced-motion mode preserves readability
- **GIVEN** reduced-motion rendering is active
- **WHEN** God-View topology is rendered
- **THEN** motion animation is disabled
- **AND** static edge styling remains clearly visible so topology relationships are still readable.
