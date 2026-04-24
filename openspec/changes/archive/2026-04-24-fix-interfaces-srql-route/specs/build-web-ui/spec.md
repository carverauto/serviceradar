## ADDED Requirements

### Requirement: Interfaces list page with SRQL search
The web UI SHALL provide an `/interfaces` route that displays a searchable list of network interfaces using SRQL queries.

#### Scenario: User navigates to interfaces page
- **WHEN** user navigates to `/interfaces`
- **THEN** the page displays a list of discovered interfaces with pagination

#### Scenario: User searches interfaces by MAC address
- **GIVEN** interfaces exist with MAC addresses
- **WHEN** user enters SRQL query `in:interfaces mac:0c:ea:14:32:d2:80`
- **THEN** the page displays only interfaces matching the MAC address filter

#### Scenario: User searches interfaces with partial MAC match
- **GIVEN** interfaces exist with various MAC addresses
- **WHEN** user enters SRQL query `in:interfaces mac:%0c:ea%`
- **THEN** the page displays interfaces with MAC addresses containing "0c:ea"

#### Scenario: Interface row links to detail page
- **GIVEN** the interfaces list is displayed
- **WHEN** user clicks on an interface row
- **THEN** user is navigated to `/devices/:device_uid/interfaces/:interface_uid` detail page

#### Scenario: SRQL catalog route matches actual route
- **GIVEN** the SRQL catalog defines `interfaces` entity with `route: "/interfaces"`
- **WHEN** the SRQL query builder navigates after an interfaces search
- **THEN** the navigation succeeds without 404 error
