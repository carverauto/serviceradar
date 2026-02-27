## 1. Implementation
- [x] 1.1 Audit God-View snapshot node payload mapping and identify why node detail fields are missing in deck.gl click selection.
- [x] 1.2 Ensure node detail payload includes identity/network context fields (`id`, `ip`, `type`, `vendor`, `model`, `last_seen`, `asn`, geo fields) when present in backend data.
- [x] 1.3 Keep detail-card rendering resilient by showing explicit fallback text for missing fields without hiding the card.
- [x] 1.4 Add/adjust frontend tests for node click and tooltip rendering to assert populated IP and metadata behavior plus fallback behavior.

## 2. Validation
- [x] 2.1 Run targeted God-View frontend tests.
- [x] 2.2 Run `openspec validate fix-god-view-node-detail-card-data --strict`.
