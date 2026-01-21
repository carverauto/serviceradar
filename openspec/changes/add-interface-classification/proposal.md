# Change: Add interface classification engine with rule-based tagging

## Why
Network devices expose many interfaces with overlapping names and IPs (e.g., UniFi/Ubiquiti routers with multiple WAN + management interfaces). We need a consistent, configurable way to classify interfaces (management, WAN, VPN/WireGuard, loopback, etc.) so dedupe/aliasing and UI can make correct decisions.

## What Changes
- Add a rule-driven interface classification engine that runs during interface ingestion.
- Persist classification results on interface records and expose them for downstream use.
- Store vendor-specific classification rules in Ash resources so a UI can manage them later.
- Seed default rules for UniFi/Ubiquiti management + WireGuard interfaces.

## Impact
- Affected specs: `interface-classification` (new)
- Affected code: mapper interface ingestion, interface resource schema, identity/alias enrichment (optional consumer)
- Data: new persisted fields for interface classifications + rule definitions
