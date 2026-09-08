## ADDED Requirements

### Requirement: SRQL search input offers catalog-driven autocompletion
The compact SRQL search input (the shared `srql_editor` component in `compact` mode, used by the navbar query bar and any other compact search reuse) SHALL offer a keyboard-driven autocompletion dropdown sourced from the SRQL catalog. Completions MUST be scoped to the token slot the cursor sits in: entity completions after `in:`, field completions in field slots, control-token completions at clause boundaries, and value completions inside a field's value slot when the field has an enumerable catalog set.

#### Scenario: Tab completes an entity after `in:`
- **GIVEN** the user has typed `in:dev` in the navbar SRQL input
- **WHEN** the user presses Tab
- **THEN** the input is completed to `in:devices ` and the dropdown closes

#### Scenario: Arrow keys cycle and Enter selects
- **GIVEN** the dropdown is open with multiple candidates
- **WHEN** the user presses ArrowDown then Enter
- **THEN** the highlighted completion replaces the active token and the dropdown closes

#### Scenario: Esc dismisses without changing the input
- **GIVEN** the dropdown is open
- **WHEN** the user presses Esc
- **THEN** the dropdown closes and the input value is unchanged

#### Scenario: Slot-scoped completions
- **GIVEN** the query is `in:devices where host`
- **WHEN** the cursor is positioned at the end of `host`
- **THEN** the dropdown offers field-name completions for the `devices` entity (e.g. `hostname`) and does not offer entity names or control tokens

### Requirement: SRQL search input flags catalog-unknown tokens with a squiggly underline
The compact SRQL search input SHALL render a wavy underline beneath any token whose kind is recognized from the SRQL grammar but whose value is not a member of the catalog set for that kind. The underline MUST not alter the input's height, font, or baseline.

#### Scenario: Unknown entity is flagged
- **GIVEN** the user has typed `in:device` (singular, not in the catalog)
- **WHEN** the input is rendered
- **THEN** the substring `device` is rendered with a wavy underline indicating the value is not a known entity

#### Scenario: Known entity is not flagged
- **GIVEN** the user has typed `in:devices`
- **WHEN** the input is rendered
- **THEN** no wavy underline is drawn

#### Scenario: Unknown field for the active entity is flagged
- **GIVEN** the query is `in:devices hostnam:server` (typo on `hostname`)
- **WHEN** the input is rendered
- **THEN** the substring `hostnam` is rendered with a wavy underline

#### Scenario: Validation degrades gracefully without JavaScript
- **GIVEN** the page is rendered with the SRQL hook unavailable
- **WHEN** the user views the navbar
- **THEN** the input is still functional as a plain `<input>` backed by the existing `<datalist>` fallback and no squiggly markup is shown

### Requirement: Clicking a token in the SRQL search input opens a slot-scoped picker
The compact SRQL search input SHALL respond to a click on any rendered token by opening the same autocompletion dropdown filtered to that token's slot, with the clicked token's text preselected so that the next selection replaces it in place.

#### Scenario: Click an entity token to pick a different entity
- **GIVEN** the input contains `in:devices` and the user clicks on the substring `devices`
- **WHEN** the click is processed
- **THEN** the dropdown opens listing all entities and selecting `logs` rewrites the input to `in:logs`

#### Scenario: Click a field token to pick a different field
- **GIVEN** the input contains `in:devices hostname:srv` and the user clicks on `hostname`
- **WHEN** the click is processed
- **THEN** the dropdown opens listing valid fields for the `devices` entity and selecting `ip` rewrites the field portion to `ip:srv`

#### Scenario: Click outside the dropdown dismisses without changes
- **GIVEN** the picker is open after a token click
- **WHEN** the user clicks elsewhere on the page
- **THEN** the dropdown closes and the input text is unchanged

### Requirement: SRQL search input may surface a hint popover for known tokens
The compact SRQL search input SHALL be capable of surfacing a non-blocking hint popover anchored to the focused or hovered token. The popover MUST contain at minimum the token's role and, when available, a short description and a preview of valid values; it MUST NOT steal focus from the input.

#### Scenario: Hint popover appears for a control token
- **GIVEN** the user focuses the cursor inside `time:`
- **WHEN** the hint affordance triggers
- **THEN** a popover renders adjacent to the token describing the time control and listing accepted forms (e.g. `last_24h`, `last_7d`) without moving keyboard focus out of the input

#### Scenario: Hint popover is dismissed on blur
- **GIVEN** the hint popover is open
- **WHEN** the input loses focus
- **THEN** the popover is removed from the DOM

### Requirement: SRQL catalog is served as JSON over `GET /api/srql/catalog` with ETag caching
The web application SHALL expose the SRQL catalog over `GET /api/srql/catalog` as authenticated JSON containing entities (each with categorized field lists: filter, numeric, boolean, array), control tokens, and the operator inventory. Responses MUST include an `ETag` header derived from the catalog content and MUST support conditional `If-None-Match` requests returning `304 Not Modified` when unchanged.

#### Scenario: Authenticated client receives the catalog
- **GIVEN** an authenticated session
- **WHEN** the client sends `GET /api/srql/catalog`
- **THEN** the response is `200 OK` with a JSON body listing entities, control tokens, and operators and an `ETag` header

#### Scenario: Conditional GET returns 304 when unchanged
- **GIVEN** a client previously received the catalog with `ETag: "abc"`
- **WHEN** the client sends `GET /api/srql/catalog` with `If-None-Match: "abc"` and the catalog has not changed
- **THEN** the response is `304 Not Modified` with no body

#### Scenario: ETag changes when the catalog changes
- **GIVEN** a known catalog ETag
- **WHEN** the catalog is mutated (a new entity, field, or control token is added)
- **THEN** the next `GET /api/srql/catalog` returns a different `ETag` value and a `200 OK` with the updated payload

#### Scenario: Unauthenticated request is rejected
- **GIVEN** a client without an authenticated session
- **WHEN** the client sends `GET /api/srql/catalog`
- **THEN** the response is `401 Unauthorized` (or the application's standard unauthenticated response) with no catalog body
