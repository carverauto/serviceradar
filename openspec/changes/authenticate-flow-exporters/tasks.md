## 1. Review
- [x] 1.1 Approve secure defaults, legacy UDP opt-in and native IPFIX TLS scope.

## 2. Implementation
- [x] 2.1 Add bounded TLS listener configuration and exporter identity validation.
- [x] 2.2 Implement mutually authenticated, authorized IPFIX stream ingestion.
- [x] 2.3 Isolate and discard parser state per authenticated transport session.
- [x] 2.4 Reject UDP templates by default and isolate explicit insecure mode.
- [x] 2.5 Update shipped configuration, chart values and migration documentation.
- [x] 2.6 Expose bounded authentication and ingress rejection metrics.

## 3. Verification and shipping
- [x] 3.1 Add owner-boundary security regressions and legitimate ingress controls.
- [x] 3.2 Obtain fresh read-only bypass/regression review of the candidate.
- [ ] 3.3 Run owner checks on RBE and synthetic live ingress checks where feasible.
- [ ] 3.4 Pass no-mistakes and personally inspect every PR CI check.
- [ ] 3.5 Merge green PR, verify issue closure and return the worktree.

Verification note: the single allowed pre-PR RBE test invocation exposed a
source-count borrow error before tests ran. The error is corrected; updated
runtime-generated PKI regressions require green PR BazelCI. Helm secure-default
and TLS opt-in renders, Rust formatting and the secret scan passed. No local
compilation, live rollout or device interoperability validation was run.

Fresh candidate review found cross-domain sampler-rate reuse. The sampler cache
is now scoped by protocol, peer transport and domain; grouped entries are
removed with domain parser eviction. The native TLS regression covers separate
retained domain rates and cold metadata after eviction.
