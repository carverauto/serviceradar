## 1. Design and schema
- [ ] 1.1 Define the grouped criteria payload for sweep target criteria (match any/all with back-compat from existing flat maps).
- [ ] 1.2 Specify SRQL OR group grammar and AST shape used by the parser and planner.

## 2. SRQL service and adapters
- [ ] 2.1 Update the Rust SRQL parser to accept parentheses with `OR` between clauses.
- [ ] 2.2 Extend SRQL planning/translation (SQL + Ash adapter) to handle OR groups.
- [ ] 2.3 Add parser and planner tests covering OR groups and mixed AND/OR expressions.

## 3. Web-ng SRQL builder
- [ ] 3.1 Add group UI (match any/all) and serialize to grouped criteria.
- [ ] 3.2 Expand field/operator catalog for devices (tags, IP CIDR/range, list membership, numeric comparisons).
- [ ] 3.3 Update SRQL generation + preview counting to use grouped logic.

## 4. Compatibility and docs
- [ ] 4.1 Preserve existing flat criteria payloads via normalization to a single group.
- [ ] 4.2 Update docs/examples to show OR group usage in SRQL.
