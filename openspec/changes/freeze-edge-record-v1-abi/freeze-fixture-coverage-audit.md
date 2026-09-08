# Freeze fixture coverage audit

Task 1.7-c requires shared Go/Elixir fixture coverage of the transport's signed
identity and finite routing vocabulary. This index distinguishes structural ABI
admission from body dispatch, current trust resolution, and deployment routing.
It is evidence for review, not approval of the freeze gate.

| Required surface | Shared artifacts | Executable evidence |
| --- | --- | --- |
| Output contract reference | `record.bin`, `record_boundary_*.bin`, `semantic_envelope_corpus.txt` | Go `TestGoldenRecordAndDelivery`, `TestRecordStructuralBoundaryCorpus`; Elixir `EdgeV1GoldenTest`, `RecordValidateTest`, `SemanticEnvelopeCorpusTest` validate presence, field widths, signed binding and digest participation |
| Authenticated producer context | `record.bin`, `service_record.bin`, publication identity and transport provenance fixtures | Go `TestGoldenPublicationIdentity`, `TestPublicationIdentityCodec`; Elixir `EdgeV1GoldenTest` recomputes identities and validates headers against record and credential context, including principal mismatch controls |
| Production authority | `production_signing_bytes.bin`, `issuer_key_a.pub`, record boundary corpus | Both golden suites recompute signed frames and verify Ed25519; structural peers check every production claim binding |
| Optional source authority | `source_signing_bytes.bin`, `issuer_key_b.pub`, `record_no_source.bin`, `record_boundary_source_absent.bin` | Both golden suites cover signing and explicit absence; structural peers validate source-present and source-absent records |
| Delivery authority | `delivery_frame.bin`, `delivery_signing_bytes.bin`, delivery renewal fixtures | Both golden suites cover delivery capability signatures and field-framed rollover/renewal claims; publication fixtures distinguish delivery identity from semantic identity |
| Registry epochs | Record boundary corpus, semantic envelope corpus, `freeze_route_registry_corpus.txt` | Zero/mismatched epoch refusals, signed and semantic digest operands, and shared positive values above uint32 in `TestFreezeRouteAndRegistryCoverage` / `FreezeCoverageTest` |
| Finite platform route profiles | `enum_policy_manifest.txt`, `freeze_route_registry_corpus.txt` and its six records | Existing enum parity covers all field contexts; the new corpus covers each of the three declared profiles with signed production/source route binding and independently decoded registry epochs |

Artifact paths are relative to `proto/edge/v1/testdata`. Go golden tests live in
`proto/edge/v1`; Go enum/semantic corpus tests live in `go/pkg/edge/edgerecord`.
Elixir golden tests live in `test/serviceradar/proto/edge_v1_golden_test.exs` under
`elixir/serviceradar_core`; its other peers live in `test/serviceradar/edge`.

The new route corpus is an envelope admission corpus: payload bytes remain opaque
at this boundary. It does not claim to exercise a recovery body dispatcher.
Ordinary routes accept both source presence states. Recovery accepts only the
source-present record with recovery authority; the source-absent record is an
explicit refusal control. All records carry freshly signed claims after mutation.
The generated enum inventory is pinned independently of the six-row manifest.

`CONTINUOUS_V1` is a declared wire value, not a deployment-active route.
`StreamRouteTest` separately pins the active durable and recovery subject topology
and rejects continuous routing. Likewise, supplying authenticated context to a
header validator tests its binding contract; these fixtures do not establish a
live TLS handshake or a deployed edge ingestion service. Key resolution and
rotation policy are separate from direct-key signature parity.

Validation targets: `//proto/edge/v1:edgev1_golden_test`,
`//go/pkg/edge/edgerecord:edgerecord_test`,
`//elixir/serviceradar_core:unit_tests_serviceradar_other`, and
`//elixir/serviceradar_core:unit_tests_serviceradar_edge`.
