# Change: Fix Aruba Device Enrichment Misclassification

## Why
Issue #2915 reports an Aruba switch being classified as Ubiquiti. The current enrichment behavior allows a Ubiquiti rule to match payloads that do not contain sufficient Ubiquiti-specific evidence. This produces incorrect vendor/type output and reduces trust in inventory classification.

## What Changes
- Tighten built-in Ubiquiti enrichment rules so they only match when Ubiquiti-specific identity evidence is present.
- Add Aruba-focused classification coverage for Aruba switch fingerprints observed in discovery payloads.
- Add regression tests that prove Aruba payloads do not trigger Ubiquiti rules while existing Ubiquiti router/switch/AP cases continue to classify correctly.
- Expose deterministic rule precedence expectations for overlapping vendor rules to prevent future cross-vendor false positives.

## Impact
- Affected specs:
  - `device-inventory`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/inventory/device_enrichment_rules/`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex`
  - `elixir/serviceradar_core/test/serviceradar/inventory/`
