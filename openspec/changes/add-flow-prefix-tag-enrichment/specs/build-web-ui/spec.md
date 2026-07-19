# build-web-ui Specification (Delta)

## ADDED Requirements

### Requirement: Flow prefix tag display and filtering

Flow investigation surfaces (the NetFlow flow listings and flow detail views) SHALL
render prefix tags for source and destination as tag chips and SHALL offer a tag
filter control that narrows the listing to flows carrying a selected tag. Rows
without tags SHALL render unchanged. The Integrations settings area SHALL provide an
IP tag-preview input that shows the most-specific-first tag chain an address would
receive from the currently active prefix tag data.

#### Scenario: Flow listing shows tag chips

- **WHEN** a user views the flow listing and a row's destination IP was enriched
  with `site:austin` and `role:guest-wifi`
- **THEN** the row renders those tags as chips on the destination side, and untagged
  rows render without a tag section

#### Scenario: Tag filter narrows the listing

- **WHEN** a user applies the tag filter `role:guest-wifi`
- **THEN** the listing shows only flows carrying that tag on source or destination,
  and clearing the filter restores the unfiltered listing

#### Scenario: Settings tag preview

- **WHEN** an authorized user enters `10.1.2.3` in the Integrations tag-preview
  input
- **THEN** the UI displays the tag chain the enrichment path would apply, ordered
  most-specific first, or an empty state when no prefix matches
