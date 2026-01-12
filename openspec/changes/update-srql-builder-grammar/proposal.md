# Change: Expand SRQL builder grammar for OR groups and operator coverage

## Why
The sweep target criteria builder can only express flat AND filters and a limited operator set, which forces users into raw SRQL and prevents accurate preview counts for common cases (for example tags has-any and IP ranges). Adding OR group support and expanding the builder operators keeps the UI aligned with SRQL capabilities without making the query language harder to use.

## What Changes
- Add SRQL grammar support for grouped boolean expressions using parentheses and the `OR` keyword, while preserving implicit AND semantics for whitespace.
- Update the sweep target criteria builder to model groups (match any/all) and generate SRQL with OR groups.
- Expand the builder's device field/operator catalog to cover existing SRQL operators such as list membership, IP CIDR/range, and numeric comparisons.
- Keep existing single-group criteria payloads valid and migratable without breaking stored configs.

## Impact
- Affected specs: srql
- Affected code: rust/srql parser + AST + planner, web-ng sweep criteria UI, SRQL query builder helpers, SRQL-to-Ash adapter parsing
