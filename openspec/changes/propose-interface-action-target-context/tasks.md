## 1. Interface action target context

- [ ] 1.1 Inventory current interface target snapshot fields, descriptor required-context validation, and sample plugin expectations.
- [ ] 1.2 Extend interface target snapshots with canonical interface ID, requested IF-MIB/display fields, and device identity fields.
- [ ] 1.3 Add optional physical-location context fields with source/provenance when mapper or integration data provides chassis/module/slot/port evidence.
- [ ] 1.4 Fail interface targets with a clear missing-context error when a plugin requires a field that is unavailable.
- [ ] 1.5 Update action history rendering so missing optional values render as omitted/unknown rather than `nil`.

## 2. SDKs and sample plugin

- [ ] 2.1 Update `~/src/serviceradar-sdk-go` target snapshot structs/helpers for richer interface context.
- [ ] 2.2 Update `~/src/serviceradar-rust-sdk` target snapshot structs/helpers for matching interface context.
- [ ] 2.3 Update the sample northbound Wasm plugin to request and display interface name, ifIndex, and physical-location fields when available.
- [ ] 2.4 Add SDK/sample tests covering absent `if_index`, present `if_index`, and modular physical-location metadata.

## 3. Device details metadata and availability

- [ ] 3.1 Remove the redundant Aliases summary card when the full IP aliases table is present.
- [ ] 3.2 Replace the "Other Metadata" hidden-key count with either no card or an explicit diagnostics expansion that lists keys only when useful and authorized.
- [ ] 3.3 Filter integration metadata cards to source-relevant operator facts, hiding API URLs, mapper job IDs, debug payloads, and implementation-only transport fields by default.
- [ ] 3.4 Ensure vendor/source cards are only shown when their fields actually apply to the device, such as not showing MikroTik API fields as a primary card for a UniFi device.
- [ ] 3.5 Make Agent Availability derive from the same persisted sweep observations shown in Recent Sweep History or explain the missing rollup condition with a repairable reason.

## 4. Device logs tab

- [ ] 4.1 Replace long-running/ambiguous log loading with a bounded SRQL-backed device log query.
- [ ] 4.2 Render a terminal empty state immediately when the SRQL log query returns zero rows.
- [ ] 4.3 Keep the full logs view link, preserving the same device filter/query context.
- [ ] 4.4 Add regression coverage for devices with no logs and devices with matching log rows.

## 5. Topology regression diagnostics

- [ ] 5.1 Compare current backbone graph query output against recent mapper/topology evidence for the demo backbone devices that should be connected.
- [ ] 5.2 Identify whether islanding is caused by missing topology ingestion, alias/canonical identity drift, edge filtering, interface attribution loss, or frontend graph grouping.
- [ ] 5.3 Add backend diagnostics or UI explainability for hidden/dropped topology edges so operators can see why connected backbone evidence is not rendered.
- [ ] 5.4 Add regression coverage for a multi-device backbone that should render as one connected component.

## 6. Validation

- [ ] 6.1 Add backend tests for interface snapshot construction and missing required context failures.
- [ ] 6.2 Add LiveView/component tests for metadata card filtering, availability consistency, task history nil suppression, and logs empty state.
- [ ] 6.3 Run focused Elixir quality/tests for touched projects.
- [ ] 6.4 Run SDK tests in Go and Rust after updating their target snapshot APIs.
- [ ] 6.5 Run `openspec validate propose-interface-action-target-context --strict`.
