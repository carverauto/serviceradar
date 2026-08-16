## 1. Contract and crate boundary

- [ ] 1.1 Create the standalone Rust package with no first-party dependencies
  and deny filesystem, persistence, transport, environment, clock, random, and process
  access in its public architecture.
- [ ] 1.2 Define semantic-only `OntologyModule` and `OntologyRelease`, stable
  resource identifiers, structured diagnostics, the V1 manifest schema, and only
  base/core sections with exact core ceilings.
- [ ] 1.3 Add dependency-boundary tests that fail if host product modules or
  host-specific vocabulary enter public core APIs or fixtures.

## 2. Semantic model and compiler

- [ ] 2.1 Implement semantic value types and constraint narrowing.
- [ ] 2.2 Implement object identity-key schemas, authority domains, immutable key
  evolution, and required scalar string title-property references.
- [ ] 2.3 Implement shared property definitions, object types, abstract
  interfaces, effective-member expansion, and deterministic multiple-inheritance
  conflict diagnostics.
- [ ] 2.4 Implement direct and object-backed `LinkType`, at least two typed roles,
  simple and multiedge identity, typed discriminator, inverse projection, and
  compatible link-resolution kinds.
- [ ] 2.5 Preserve namespaced extension annotations without allowing them to
  alter core semantic behavior.
- [ ] 2.6 Implement pure compilation, reference resolution, cycle checks, profile
  admission, and stable diagnostic ordering.

## 3. Releases, compatibility, and artifacts

- [ ] 3.1 Implement immutable release compilation and stable content identities.
- [ ] 3.2 Implement additive, compatible-with-migration, and breaking diff
  classification plus migration-metadata validation.
- [ ] 3.3 Implement the typed logical model, exact RFC 8785 wrappers, deterministic
  CBOR native i64/time and decimal tag 4, logical-ID array hash, and separate wire
  hashes.
- [ ] 3.4 Add exact golden vectors for integer widths, signed UTC microseconds,
  duration, date days, bytes, URI, enum, object reference, decimal normalization,
  list order, set CBOR ordering, contract-kind/version bounds, Unicode non-
  normalization, duplicate/unknown fields, corruption, and cross-encoding ID.

## 4. Portability verification

- [ ] 4.1 Publish language-neutral positive and negative corpus vectors for every
  resource kind, inheritance rule, relationship form, limit, and diagnostic.
- [ ] 4.2 Publish cross-encoding golden artifacts, logical IDs, both wire hashes,
  compatibility diffs, migrations, exact values, Unicode cases, closed-field
  failures, corruption cases, and base/core manifest sections.
- [ ] 4.3 Implement a conformance runner that consumes only the portable corpus
  contract and fails on semantic, ordering, encoding, or diagnostic drift.
- [ ] 4.4 Document the stable public contract and reserve kinetic ontology,
  actions, policies, arbitrary functions, and workflows for future proposals.

## 5. Approval gate

- [ ] 5.1 Obtain approval of the core contract and conformance corpus before
  implementing `add-portable-ontology-runtime`.
