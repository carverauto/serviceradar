## ADDED Requirements
### Requirement: Analytics page hides SRQL search input
The web-ng analytics page SHALL not render the SRQL search input in the top navigation.

#### Scenario: Analytics page header
- **GIVEN** an authenticated user viewing the analytics page
- **WHEN** the page renders
- **THEN** the top navigation does not show the SRQL search input
