## ADDED Requirements

### Requirement: Dashboard Frame Cursor Paging

The dashboard package host SHALL page a declared data frame through SRQL
cursors without rewriting the frame's query string.

`FrameRunner` SHALL pass `cursor` from the frame map into
`srql_module.query/2` (and `query_arrow/2`) alongside `scope` and `limit`.
A frame result SHALL include the SRQL `pagination` object (`next_cursor`,
`prev_cursor`, `limit`) when the SRQL response carries one.

The host SHALL expose `api.srql.page(frameId, cursor)` to trusted browser
modules that hold the `srql.execute` capability. Invoking it SHALL re-run
**only** that frame at the given cursor and SHALL NOT remount the
renderer, SHALL NOT `push_patch` the dashboard URL, and SHALL NOT change
other frames.

`api.srql.update` SHALL reset paging for every frame whose query it
replaces. Cursors SHALL remain request metadata; the SRQL grammar SHALL
NOT gain a `cursor:` token.

#### Scenario: Next page of a row frame

- **GIVEN** a dashboard frame `results` whose query is
  `in:composite_results sort:device_uid:asc limit:200`
- **AND** the first run returned 200 rows and `pagination.next_cursor`
- **WHEN** the renderer calls `api.srql.page("results", next_cursor)`
- **THEN** FrameRunner SHALL re-run that query with the cursor
- **AND** the renderer SHALL receive a `frames:replace` (or equivalent)
  containing the next page for `results` only
- **AND** the dashboard URL query string SHALL be unchanged
- **AND** the renderer SHALL remain mounted

#### Scenario: Page does not leak across query updates

- **GIVEN** a paged `results` frame
- **WHEN** the renderer calls `api.srql.update` with a new `results` query
  (for example `check:pci-isolation`)
- **THEN** the next run SHALL start at offset 0
- **AND** SHALL NOT reuse the previous cursor

#### Scenario: Capability gate

- **GIVEN** a package whose capabilities do not include `srql.execute`
- **WHEN** the renderer calls `api.srql.page`
- **THEN** the host SHALL throw the same capability error it uses for
  `api.srql.update`

#### Scenario: Missing cursor is not a query replace

- **WHEN** the renderer calls `api.srql.page("results", "")` or omits the
  cursor
- **THEN** the host SHALL reject the call
- **AND** SHALL NOT run `api.srql.update`

### Requirement: Stats Frames Versus Row Frames

A dashboard package MAY declare a data frame whose query uses `stats:`.
The host SHALL run that query through the same FrameRunner path as a row
frame. A stats frame that returns fewer rows than its `limit` SHALL NOT
be treated as truncated.

Row frames that resolve device labels via `in:devices uid:(…)` SHALL
declare a `limit` no greater than the SRQL filter list cap (200) so every
uid on the page can be named in one devices query.

#### Scenario: Stats frame is not a ceiling warning

- **GIVEN** a frame
  `in:composite_results stats:count() as n by check,verdict` with
  `limit: 500`
- **AND** the query returns 12 groups
- **THEN** the host SHALL report `pagination.next_cursor` as null
- **AND** a renderer MUST NOT treat the frame as truncated

#### Scenario: Hostname lookup fits the page

- **GIVEN** a results frame of `limit: 200`
- **WHEN** the renderer builds `in:devices uid:(…)` from that page's
  `device_uid` values
- **THEN** the uid list SHALL contain at most 200 values
- **AND** SRQL SHALL accept the list
