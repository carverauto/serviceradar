## ADDED Requirements

### Requirement: Keyset cursors for pages ordered by a unique key
SRQL SHALL page a query whose effective order is a single unique, indexed keyset key declared by its entity (initially `uid` on `devices` and `agents`) by key position instead of by row offset: the next page SHALL be selected with a strict comparison against the previous page's last key value and SHALL NOT use `OFFSET`.

The cursor for such a page SHALL be a signed keyset cursor that binds the entity, key column, direction and last key value, minted by the component that executed the page from that page's last row and issued only when the page was full. A keyset cursor SHALL NOT be subject to the maximum cursor offset. Keyset paging SHALL be forward-only. Queries whose order is not keyset-eligible SHALL keep signed offset cursors with their existing behaviour, and an offset cursor presented to a keyset-eligible query SHALL still be honoured.

#### Scenario: Walking a uid-ordered device selection
- **GIVEN** a device selection larger than one page
- **WHEN** a caller pages `in:devices sort:uid:asc` with `limit:1000`, following each `next_cursor`
- **THEN** every page after the first SHALL be read with `uid > <last uid of the previous page>` and no `OFFSET`
- **AND** every matching device SHALL be returned exactly once
- **AND** the final, short page SHALL carry no `next_cursor`

#### Scenario: A walk past the offset window
- **GIVEN** a uid-ordered selection with more rows than the maximum cursor offset
- **WHEN** a caller follows `next_cursor` to the end
- **THEN** SRQL SHALL keep issuing cursors until the selection is exhausted

#### Scenario: A keyset cursor replayed against a different order
- **GIVEN** a keyset cursor minted for `in:devices sort:uid:asc`
- **WHEN** it is presented with `in:devices sort:uid:desc` or `in:agents sort:uid:asc`
- **THEN** the request SHALL be rejected as an invalid cursor

#### Scenario: An offset cursor straddling an upgrade
- **GIVEN** an offset cursor issued for `in:devices sort:uid:asc` before keyset cursors existed
- **WHEN** it is presented after the upgrade
- **THEN** the page SHALL be read at that offset
- **AND** its `next_cursor`, when issued, SHALL be a keyset cursor

#### Scenario: Interactive default order keeps offset paging
- **GIVEN** `in:devices` with no explicit sort
- **WHEN** a caller requests the next or previous page
- **THEN** SRQL SHALL use offset cursors exactly as before, including `prev_cursor`

#### Scenario: Backward paging is refused for keyset cursors
- **GIVEN** a keyset cursor
- **WHEN** it is presented with `direction: "prev"`
- **THEN** the request SHALL be rejected
