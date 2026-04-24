## ADDED Requirements

### Requirement: Consistent interface status badge sizing

The web-ng UI SHALL render network interface status badges with fixed minimum widths so that all status labels display at uniform sizes regardless of text length.

#### Scenario: Oper status badges render at consistent width
- **GIVEN** a list of network interfaces with varying operational statuses (Up, Down, Testing, Unknown)
- **WHEN** the interfaces are displayed in the device detail interfaces table
- **THEN** all oper status badges SHALL render at the same minimum width
- **AND** shorter labels (e.g., "Up") SHALL be centered within the badge

#### Scenario: Admin status badges render at consistent width
- **GIVEN** a list of network interfaces with varying admin statuses (Enabled, Disabled, Testing, Unknown)
- **WHEN** the interfaces are displayed in the device detail interfaces table
- **THEN** all admin status badges SHALL render at the same minimum width
- **AND** shorter labels (e.g., "Enabled") SHALL be centered within the badge

#### Scenario: Interface detail header status badges match table badges
- **GIVEN** a user viewing an interface detail page
- **WHEN** the interface status badges are displayed in the header
- **THEN** the badges SHALL use the same fixed-width styling as the interfaces table
