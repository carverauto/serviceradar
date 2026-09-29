## 1. Implementation

- [ ] 1.1 Stable provider-scoped object identity, observed time and provenance, coordinate reference/version, position and optional motion/quality fields form one atomic observation.
- [ ] 1.2 Specify geographic vs Cartesian coordinates, units/axes, altitude conventions, finite/range validation, size/rate limits, producer handoff, equal-time conflicts and future-clock policy.
- [ ] 1.3 Reuse negotiated edge record/host capability contracts; inspect the producer-neutral work in #4905 before extending the ABI. Unsupported capabilities/versions fail explicitly.
- [ ] 1.4 Add matching Go and Rust builders and host admission with invented cross-language conformance vectors. Coordinate with #4846's general Rust SDK parity work; do not duplicate its existing capabilities.
- [ ] 1.5 Plugins emit semantic records, never choose CNPG/StarRocks tables, S3 buckets or Dgraph predicates. Trusted host context supplies authoritative provenance.

## 2. Acceptance

- [ ] A non-device fixed object and a moving object encode/decode consistently in both SDKs.
- [ ] Unsupported version, invalid coordinates, oversized/rate-exceeding records and conflicting producer cases fail visibly without silent loss.
- [ ] Identity and provenance survive retries/replay; object identities are not forced into device inventory.
- [ ] Existing plugin/edge capabilities remain compatible and documented.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
