# Tasks

## 1. Grouping

- [x] 1.1 Add a `Jsonb { column, key }` variant to `DeviceGroupField`, parsed from
      `tags.<key>` / `metadata.<key>` and validated with `is_valid_jsonb_key`
- [x] 1.2 Emit `COALESCE(<column>->>'<key>', 'Unknown')` for the group expression
      and the full path (`tags.gate`) for the response key and `sort:`
- [x] 1.3 Name the supported grouping fields from one constant so the parse error
      cannot drift from what is accepted

## 2. Filter parity

- [x] 2.1 Route `tags.<key>` and bare `tags:<key>` through the grouped-stats
      filter builder, alongside the existing `metadata.<key>` support
- [x] 2.2 Add `In` / `NotIn` to `apply_jsonb_text_filter` and to the grouped
      clause builder, with the negated form keeping rows missing the key
- [x] 2.3 Collect bind params for the same operator set in
      `collect_filter_params`, including the fixed `os.*` / `hw_info.*` paths,
      so execution and translation cannot diverge
- [x] 2.4 Promote wildcard values on `tags.<key>` to LIKE / NotLike and route
      fixed `os.*` / `hw_info.*` paths through the grouped-stats filter builder

## 3. Case sensitivity

- [x] 3.1 Case-fold only the namespace in `parse_group_field`
- [x] 3.2 Case-fold only the namespace in the parser's field normalization, so a
      filter and a group-by address the same key
- [x] 3.3 Preserve JSONB sub-key casing in `sort:` and resolve dynamic grouped
      fields case-sensitively

## 4. Execution correctness

- [x] 4.1 Rewrite `?` to `$n` on the device execute path before `sql_query`
- [x] 4.2 Spell the grouped tag-existence check as `jsonb_exists` /
      `jsonb_exists_any` so placeholder rewriting cannot mangle the operator

## 5. Tests

- [x] 5.1 Unit: key parsing, rejection of unsafe/oversized/nested keys, mixed case
- [x] 5.2 Unit: generated SQL and bind params for grouping, filtering, list form,
      and the assertion that no raw `?` survives
- [x] 5.3 Integration (DB-backed): grouped stats execute against Postgres,
      including the filtered case that the unit tests structurally cannot catch
- [x] 5.4 Seed device `tags` in the SRQL integration fixtures, with one
      deliberately mixed-case key and one untagged device
- [x] 5.5 Run the DB-backed grouped-stats target explicitly in CI and keep its
      inactive-device expectations aligned with the fixture's query defaults

## 6. Docs

- [x] 6.1 Document JSONB grouping, the `Unknown` bucket, and the 20/100 limits
- [x] 6.2 Correct the `tags` field description: it is a JSONB map, and the bare
      form is a key-existence test
- [x] 6.3 Advertise `tags.<key>` and `metadata.<key>` through the SRQL catalog
