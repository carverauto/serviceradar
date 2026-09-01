## 1. Ingest
- [ ] 1.1 Extend the log processor's identity derivation to consider device attributes on an
  OTLP record, using the key set events already accept.
- [ ] 1.2 Prefer a device identity over a host address when both are present.
- [ ] 1.3 Accept both resource and record attributes, with the record attribute winning.
- [ ] 1.4 Store nothing when the attribute resolves to no known device; do not approximate.
- [ ] 1.5 Leave syslog, GELF and trap derivation untouched.

## 2. Tests
- [ ] 2.1 A record attributed by address is returned by a device log query.
- [ ] 2.2 A record attributed by identity is returned by a device log query.
- [ ] 2.3 Identity wins over address when both are present.
- [ ] 2.4 An unattributed record is stored and queryable as before.
- [ ] 2.5 An unresolvable attribute stores the record unattributed rather than guessing.
- [ ] 2.6 Syslog correlation is unchanged.

## 3. Documentation
- [ ] 3.1 Document the attribute contract in the OTEL ingest guide, next to the endpoints
  and quickstarts, as a producer-facing convention.
- [ ] 3.2 Note that the keys are the same ones events accept.

## 4. Before merge
- [ ] 4.1 Measure the added ingest cost at a representative OTLP log rate.
- [ ] 4.2 Confirm whether the derived identity should be visible on the log row for
  diagnosing a mis-attribution.
