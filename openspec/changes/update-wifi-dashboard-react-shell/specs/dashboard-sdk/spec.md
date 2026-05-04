## ADDED Requirements

### Requirement: React-mounted Mapbox popup helper
The dashboard SDK SHALL provide a React hook that mounts arbitrary React content into a managed `mapboxgl.Popup` instance, owns the popup lifecycle, and renders content updates without recreating the popup, so dashboard packages do not implement the React-to-Mapbox-popup bridge themselves.

#### Scenario: Open a popup with React content
- **GIVEN** a dashboard package has a Mapbox map handle and a focused feature
- **WHEN** the package calls `useMapPopup(map).open({coordinates, content})` with a React node as `content`
- **THEN** the SDK SHALL create a `mapboxgl.Popup` if one is not already open
- **AND** it SHALL mount the React content into the popup's content node via `createRoot`
- **AND** it SHALL position the popup at the supplied coordinates

#### Scenario: Update React content without recreating the popup
- **GIVEN** a popup is open with a React content node
- **WHEN** the dashboard package re-invokes `popup.open({coordinates, content})` with a new React node
- **THEN** the SDK SHALL re-render the React subtree inside the existing popup
- **AND** it SHALL NOT remove and recreate the underlying `mapboxgl.Popup`
- **AND** it SHALL NOT re-anchor the popup unless the coordinates change

#### Scenario: Close the popup releases the React root
- **GIVEN** a popup is open with a React content node
- **WHEN** `popup.close()` is invoked, the user clicks elsewhere on the map and `closeOnClick` is true, or the parent component unmounts
- **THEN** the SDK SHALL unmount the React root before removing the popup from the map
- **AND** it SHALL NOT leak React roots or fire orphaned-state warnings on subsequent renders

#### Scenario: Missing host libraries surface a clear error
- **GIVEN** the host has not injected `mapboxgl` or the package is mounted without a map handle
- **WHEN** a dashboard component calls `useMapPopup(undefined)` or invokes `popup.open(...)` before the map is ready
- **THEN** the SDK SHALL return a no-op handle while the map handle is missing
- **AND** it SHALL emit a console warning identifying the missing dependency
- **AND** it SHALL NOT throw during render or break the dashboard tree

#### Scenario: Stable callback identities across renders
- **GIVEN** a dashboard component consumes `useMapPopup`
- **WHEN** the component re-renders without a config change
- **THEN** the returned `open` and `close` callbacks SHALL be referentially equal across renders
