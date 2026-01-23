## ADDED Requirements
### Requirement: Mapper interface count accuracy
Mapper interface results MUST report the count of unique interfaces after applying canonicalization and de-duplication rules.

#### Scenario: De-duplicated interface count in results
- **GIVEN** mapper discovery emits duplicate interface updates for the same device/interface key
- **WHEN** the agent streams mapper interface results to the gateway
- **THEN** the reported interface count SHALL equal the number of unique interfaces in the payload
- **AND** duplicate interface updates SHALL not inflate the count
