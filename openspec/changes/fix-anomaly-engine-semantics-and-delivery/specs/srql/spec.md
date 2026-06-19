## ADDED Requirements

### Requirement: Canonical Flow Conversation Grouping
The SRQL service SHALL expose canonical bidirectional conversation group-by fields for `in:flows` stats queries.

#### Scenario: Group flows by unordered endpoint pair
- **GIVEN** flow rows include traffic from endpoint A to endpoint B and from endpoint B to endpoint A
- **WHEN** a user queries `in:flows time:last_1h stats:"sum(bytes_total) as bytes_total by conversation_a_ip, conversation_b_ip"`
- **THEN** SRQL returns one row for the unordered endpoint pair
- **AND** the row keys `conversation_a_ip` and `conversation_b_ip` contain the same endpoint ordering for both directions
