## ADDED Requirements

### Requirement: Compact SRQL search input preserves the plain-input visual contract
The compact SRQL search input rendered in the navbar query bar (and any other compact reuse of `srql_editor`) SHALL be visually indistinguishable from a single-line plain `<input>` while idle. Any added intelligence (autocompletion dropdown, validation underline, hint popover, click-token picker) MUST be implemented as additive overlays anchored to the input and MUST NOT change the input's height, font family, font size, padding, border, background, or focus ring relative to the existing `srql_editor compact={true}` styling.

#### Scenario: Idle navbar input matches plain input dimensions
- **GIVEN** a page that renders the navbar SRQL query bar
- **WHEN** the input has not received focus and the user has not interacted with it
- **THEN** its rendered geometry (height, font, padding, border, background, focus ring) matches the existing compact `srql_editor` styling and contains no visible dropdown, popover, or token markup

#### Scenario: Monaco is not used in compact mode
- **GIVEN** any reuse of `srql_editor` configured with `compact={true}`
- **WHEN** the component is rendered
- **THEN** the rendered input is a single-line `<input type="text">` and no Monaco editor instance is constructed for that input

#### Scenario: Rich mode is unaffected
- **GIVEN** a page that uses `srql_editor` with `rich={true}` (e.g. the self-authored dashboard editor or the MTR profile editor)
- **WHEN** the component is rendered
- **THEN** the existing Monaco-backed rich editor continues to mount and behave as it does today, with no changes from this proposal

#### Scenario: JS-disabled fallback remains a usable input
- **GIVEN** JavaScript is disabled or the SRQL input hook fails to mount
- **WHEN** the navbar renders
- **THEN** the input is a working `<input>` with the existing `<datalist>` providing native browser autocomplete, and no broken overlay markup is visible
