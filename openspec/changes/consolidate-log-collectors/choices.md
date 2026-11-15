# Implementation choices

This ledger distinguishes implemented foundations from approved future design.
All entries are sound on current evidence; medium-confidence choices remain
benchmark candidates rather than claims of an optimum.

## Medium confidence

- **Publisher defaults: 32 pending records and 8 MiB per worker.** When one
  ACK is slow, other admitted records can progress. A window of one restores
  serial operation for comparison. These are configurable starting values,
  not measured optima. Existing multiple-worker configuration multiplies these
  limits; upstream queue and client/TLS memory are additional.
- **Future sharding uses collector routing and immutable epochs.** A source
  remains assigned to one shard for an epoch; changing shard count creates
  another epoch so retries can finish where they started. Server-side NATS
  partition mapping exists, but hashing after a mixed-source batch is built
  cannot separate its records. The proposed collector hash is SHA-256 with
  frozen vectors; this routing is not implemented in the foundation pass.
- **External Service migration has explicit precedence.** If only the old TCP
  external block is enabled, its metadata and ports survive on the unified
  Service. When the primary external block is enabled, its metadata wins;
  active legacy TCP port settings remain applicable. Conflicting pinned
  addresses fail instead of choosing one silently.

## High confidence

- **One logical output, existing publisher workers preserved.** Adding TCP must
  not start another complete NATS output. Operators explicitly configuring
  multiple workers retain them; the proposal no longer incorrectly promises
  exactly one connection for every configuration.
- **Listener failure ends the collector.** If TCP fails while UDP continues,
  generic health can incorrectly imply all configured inputs are working.
  Supervision propagates the failure to the existing process-exit path.
- **Oversized publish admission fails explicitly.** A record larger than the
  entire configured byte budget cannot ever acquire capacity. Terminating the
  output follows its existing fatal-error policy and avoids silent dropping or
  indefinite waiting.
- **Reconnect ownership is shared, in-flight guards stay alive.** Pending ACKs
  retain their original connection and certificate guard while one replacement
  connection is established for retries. Stable IDs and existing ambiguity
  deadlines remain applicable.
- **Source closure drains under the configured retry policy.** ACK-ambiguous
  retries are bounded. An operator's existing unlimited reconnect-before-store
  configuration is preserved, so no unconditional finite shutdown deadline is
  claimed.
- **The old TCP Service is an identified compatibility consumer.** Existing
  senders can retain its address while it selects only unified TCP-listening
  pods. It is an alias, not another workload or data pipeline.
- **Specialized receivers remain optional.** Ordinary VM-backed Kubernetes
  workers and edge VMs remain supported. Acceleration does not change Zen,
  wire identity, persistence or loss accounting.

- **Explicit custom TCP target ports remain supported.** A numeric legacy TCP
  target port is declared on the unified pod and used by the primary and
  compatibility Services; the configured listener must match it. This preserves
  the existing operator control instead of silently sending to port 514.

- **Shared normalization reproduces the JSON-text results exactly.** JSON
  numbers keep their original text until a rule returns them, and a number
  Zen cannot hold survives at the top level. A simpler conversion would have
  rewritten `1.0` as `1` in fields no rule returned and turned `1e300` into
  `null`. Two inherited behaviors are preserved, not endorsed: a top-level
  `null` result does not remove a field, and a nested unrepresentable number a
  rule returns becomes `null`.
- **Each rule evaluates a copy of the record's containers.** Strings are
  shared. Passing the record itself would be cheaper, but nothing establishes
  that every Zen node type leaves its context unchanged.

