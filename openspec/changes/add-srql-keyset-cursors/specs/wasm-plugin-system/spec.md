## MODIFIED Requirements

### Requirement: Policy Target Queries Are Read Whole
The control plane SHALL read the whole selection of a plugin target policy's input definitions, a credential rule's target query, and a producer schedule's `target_query` or `target_input` query whenever it plans, retracts, dispatches, or previews from them, a page at a time with an explicit page limit. It SHALL NOT treat one SRQL page as the whole selection. Device and agent selections SHALL be paged in `uid` order so that SRQL serves them with keyset cursors, and their size SHALL NOT be limited by SRQL's maximum cursor offset. A selection that cannot be read whole SHALL fail the operation rather than act on, or report, a partial selection. A preview SHALL report the whole selection's counts, and any list it shows SHALL be bounded and labelled as a sample.

#### Scenario: Credential rule selecting more than one page
- **GIVEN** an enabled credential rule whose target query selects more devices than one SRQL page returns
- **WHEN** the rule is reconciled for its agent
- **THEN** every selected device is delivered in one of the rule's assignments

#### Scenario: Editing a wide target policy
- **GIVEN** an enabled target policy whose input selects more agents than one SRQL page returns, with an enabled assignment on each
- **WHEN** an operator changes the policy's input definitions without excluding any of those agents
- **THEN** no assignment is retracted

#### Scenario: Previewing a wide selection
- **GIVEN** a credential rule or target policy whose query selects more devices than one SRQL page returns
- **WHEN** an operator previews it
- **THEN** the preview reports the number of devices the whole selection matches
- **AND** any device list it shows is bounded and labelled as a sample

#### Scenario: Producer schedule target items beyond one page
- **GIVEN** a producer schedule whose `target_input` query matches more devices than its `max_items`
- **WHEN** the schedule dispatches
- **THEN** the run carries at most `max_items` items, the total the whole query matched, and a truncation flag

#### Scenario: Device selection larger than the cursor window
- **GIVEN** an add-on profile, target policy or credential rule whose device target query matches more devices than SRQL's maximum cursor offset
- **WHEN** the control plane reads it
- **THEN** every matching device is read, using keyset cursors
- **AND** the operation proceeds on the whole selection

#### Scenario: Selection cannot be read whole
- **GIVEN** a target query whose entity is not paged by keyset and whose selection continues past SRQL's cursor window, or whose page read fails
- **WHEN** the control plane reads it
- **THEN** the operation fails with an error naming the cause
- **AND** nothing is planned, retracted, or dispatched from a partial selection
