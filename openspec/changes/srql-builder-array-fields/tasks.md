## 1. Implementation

- [x] 1.1 Add `array_fields` list to devices entity in SRQL Catalog (`discovery_sources`, `tags`)
- [x] 1.2 Update `build_equals_token/2` in Builder to check if field is an array field
- [x] 1.3 For array fields, always use list syntax even for single values: `field:(value)`
- [ ] 1.4 Consider adding array_fields to other entities if applicable

## 2. Testing

- [ ] 2.1 Test that `discovery_sources` filter with single value generates `discovery_sources:(armis)`
- [ ] 2.2 Test that multiple values still work: `discovery_sources:(armis,sweep)`
- [ ] 2.3 Test that non-array fields are unchanged: `hostname:foo` (not `hostname:(foo)`)
- [ ] 2.4 Test that parsing existing queries still works correctly
- [ ] 2.5 Verify search results match for both syntaxes
