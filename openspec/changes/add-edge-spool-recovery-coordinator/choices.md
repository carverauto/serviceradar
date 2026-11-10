# Recovery implementation choices

These are the consolidated implementation decisions under the approved design,
checked against the integrated code. Run results and deliberate failing controls
belong in [verification.md](verification.md).

Review the two medium-confidence operational choices first: the two-attempt limit
and mandatory archive retention. Both preserve safety but can leave recovery
pending under repeated failures or sustained rejected traffic. The remaining
choices have high confidence. No unsound or unresolved user-only decision remains.

## Sound decisions

### Preserve publication attempts instead of rewriting them

**Verdict: sound; medium operational confidence; high safety confidence.**

Each complete control bundle is immutable. A fresh authority attempt keeps the
semantic manifest/root but has fresh transport events and capabilities. An
interrupted append replays the same frozen bundle into a separate attempt.
Receipts identify the exact attempt; audit-only ACKs cannot establish coverage.

At most two attempts are reserved. A third refuses visibly before allocation.
For example, a torn first attempt can consume the second attempt on replay; a
later authority change then leaves the operation pending. Extra disk alone does
not increase this fixed attempt limit.
Paired journal and phase repair restores only evidence proved by the surviving
intact copy; it never chooses between conflicting valid copies or overwrites
healthy committed data. Data-copy repair has a different proof: it may finish the
frozen final allocation in a fresh dedicated destination from an intact reopened
source and frozen copy intent. It verifies the previous committed end, counters,
identical existing byte prefixes and both storage holds. This permits restart
after PREPARED, before a destination COMMITTED copy exists.

### Keep source reclaim and journal cleanup separate

**Verdict: sound; medium operational confidence; high safety confidence.**

A source can be reclaimed after complete durable local coverage. Both journal
copies and page proofs remain until the consumer's signed immutable completion
is durable locally. Restart revalidates that completion under current retained-key
policy; an old production validity window does not erase a completed fact, while
compromise-revoked or unavailable signing keys refuse cleanup.

One grant covers destination storage, both journals and repairs, control attempts,
mandatory archives and metadata. Its default footprint is 47 MiB, plus the existing
1 MiB physical floor within the 1 GiB total default. Journal copies each reserve
6 MiB; controls reserve 3 MiB. Retained rejection and control archives remain
charged after cleanup. Exhausting an operation's archive reserve leaves that
recovery pending with its remaining records and required evidence retained; the
original source is retained only when exhaustion occurs before `ReclaimSource`
succeeds, since later destination or control archive writes can refuse after the
source is reclaimed. Accumulated mandatory
archives can separately pause producer admission at the shared pressure or capacity
limit. Neither condition deletes evidence or permits unlimited recovery attempts.
A workload whose records are all permanently rejected can fill required archives;
the 47 MiB reserve proves bounded scratch sufficiency, not endless forward progress
under that workload.

### Recover bounded generations; retain unsupported flat storage

**Verdict: sound; high confidence.**

New producers use attributed generations with independent sequence spaces for
finite `(route profile, traffic class)` lanes. The recovery route uses BULK,
matching the issued catalog grant; it is separate from the ordinary BULK route.
One worker per lane prevents an ordinary gap from stopping recovery delivery.

The owner excluded legacy compatibility. Existing flat files remain untouched,
measured and reported as unsupported retained storage. There is no legacy drain,
migration, copy-only protocol or inferred historical identity. This preserves
bytes without claiming that the old gap is repaired.

The same boundary applies to sweep leases. A lease cached before core recorded
issuance evidence is never loaded, and its file stays on disk unchanged. Each
new control session instead gets a fresh, evidence-backed full window. The
session retries that refresh with bounded backoff until it succeeds or the
session ends, so one failed attempt cannot strand an acknowledged window.
A refresh evaluates and plans only its own agent; it never revokes, re-plans or
withdraws another agent, which stays the lease pass's job. The pass and refreshes
serialize one agent's lease of one group on a cluster-wide `:global.trans` lock
across connected nodes, not a node-local one, because core runs on several nodes.
The lock covers the fresh delivery read, the separately committed issuance,
`record_push` and the send; it does not wrap them in a database transaction.

### One owner accounts for every retained byte

**Verdict: sound; high confidence.**

The filesystem allocator owns ordinary usage, recovery reservations and the
physical free-space floor. Admission's Gate reads that accounting for pressure
and fairness; the unused Controller and its second reclaim ledger are removed.
Every filesystem probe measures the actual spool directory. A failed probe
refuses capacity rather than assuming that space exists.

A generation's fixed metadata is charged before its directory is created.
An invalid configured budget pauses producer admission until a valid value is
applied, including a correction back to the last accepted value. Delivery and
reserved recovery can continue. No fallback silently enlarges the operator's
budget, and no refusal deletes an admitted record.

### Bound generations before allocating their sequences

**Verdict: sound; high confidence.**

Existing generation rotation bounds the complete relocation cost, including
record wrappers, commit evidence, attribution, mappings and terminal allowance.
Slot and worst-case manifest limits also apply. A nonempty generation rotates
retryably before an oversized append allocates a sequence. An empty generation
that cannot fit one valid record refuses retryably for capacity correction.

One operation admits at most 1024 allocated slots, four pages, 256 KiB of exact
manifest bytes and a 512 KiB registration. Admission of new attributed generations
keeps their worst-case manifests inside those limits. Coarsening never removes
proven attribution to fit a budget, and copies-only work cannot invent a loss.

### Attribution comes from the record's signed operands

**Verdict: sound; high confidence.**

Typed constructors invoke the existing contract validators and capture the full
validated attribution. They compare production and source scopes separately,
including source presence, kind and contract-owned correlation operands. A
producer cannot supply a second independently trusted classification.

Each stored sequence has an independently checksummed binding to its namespace,
lane, spool, sequence, event, exact record hash and full attribution. Generation
options use that generation's frozen identity, even after re-enrollment. Record,
sidecar and relocation mapping durability precede an append receipt. A corrupt
binding becomes explicit unattributable evidence. Commit or fsync failure retains
data and stops that spool handle; reserve write failures retain the stopped grant.
Restart reopens inventory and evidence before continuation. Safe capacity refusals
remain retryable without a restart. Relocation preserves the exact record and
rebinds its physical location.

### Historical mapping outlives mutable assignments

**Verdict: sound; high confidence.**

Mapping values are tagged positive or explicit negative. Missing is never a
negative. Original issuance evidence commits before signed authority is returned;
repair can use only that original evidence. Assignment and execution-slot
lifecycle deletion cannot cascade into the mapping ledger.

Conflicting candidates and resolution records remain retained. The first valid
selection for one candidate generation is immutable, even under a newer resolver
epoch. A genuinely new candidate invalidates the selected projection and requires
explicit resolution. No elapsed-time deletion or safe mapping-GC API is claimed.

### Register intent before issuing recovery authority

**Verdict: sound; high confidence.**

Core registers immutable source bounds, namespace, lane, destination, exact pages,
tombstone and copy coordinates. Copy declarations and loss spans must partition
the selected interval. Registration is control metadata, not a broker receipt or
proof of a committed local copy.

The authenticated agent channel owns identity; request fields cannot grant scope
membership. Separate RPCs register the operation, authorize exact registered
controls, renew exact registered copies and query completion. Copy grants also
require original mapping evidence and current retained signing-key policy. A
removed assignment may permit audit delivery under a registered rollover; it does
not authorize new authoritative projection.

Hello's version is a feature snapshot for the managed gRPC connection. A new
accepted Hello replaces it, failed Hello invalidates it, and replacing the managed
connection requires negotiation again. Ordinary gRPC transport retries retain the
feature snapshot. A complete gateway build advertises one; temporary core
unavailability is a retryable RPC failure rather than a permanent zero-version
enrollment. Deploy core first. Every recovery RPC, grant and completion still verifies its own
authority; this version is not an authorization or freshness cache.

### The storage owner proves coverage

**Verdict: sound; high confidence.**

Before classification, the coordinator excludes, cancels and joins the source's
live sender. Reserved destination creation and source closure share one recovery
grant. A storage-owned builder freezes the full retained physical interval,
including acknowledged bytes not yet reclaimed and allocated markerless slots.
The durable source hold prevents later ordinary reclaim.

Two matching checksummed journal copies retain each selected sequence's complete
loss classification or committed-copy intent. The storage owner builds pages
from that evidence. Only adjacent lost sequences with identical complete bodies
merge. Preserved gaps, differing attributed operands and differing unattributable
reasons remain separate.

A journal alone permits no deletion. Source reclaim requires fully committed,
sender-visible destination copies or authoritative page receipts whose membership
and complete bodies match the per-sequence evidence. It persists intent before
physical deletion. Destination holds preserve the commit witnesses until both
coverage copies are durable.

### Keep transport behind the durability boundaries

**Verdict: sound; high confidence.**

The sender validates an ACK once, then calls the recovery receipt writer before
persisting its ordinary terminal prefix. A receipt-write failure leaves the
record replayable across restart. The sender neither classifies loss nor creates
coverage proof.

Recovered copies always require their registered rollover delivery grant, even
while their original production grant is current. Missing or expired copy grants
cannot fall back to ordinary authority. If a later grant is missing, the sender
can resolve the already-sent prefix and retains the remaining suffix.

### Inventory before starting producers and senders

**Verdict: sound; high confidence.**

Restart first measures retained recovery files and restores their grants from
storage-owned inventory. Temporary ordinary accounting transfers measured bytes
to the existing recovery grant without pretending that a transfer is a deletion.
Unassociated or inconsistent files block readiness visibly.

The coordinator advances bounded discovery, copy, publication, receipt and cleanup
steps. It restores stored operation intent before using current configuration and
resumes the durable phase rather than restarting destructive work. Consumer-pending
status remains distinct from an unreadable or unavailable spool; health retains
counts, ages, generation-qualified gaps and budget usage.

### Consumer repair commits before completion

**Verdict: sound; high confidence.**

Received-page and operation keys contain identity only. Digests, manifest roots
and destination IDs are compared values, so a conflicting replay cannot insert a
second apparently independent recovery. Registration and received evidence stay
separate. An incomplete exact page receipt may ACK after durable storage; the
record completing assembly remains deferred while repair is unavailable or blocked.

One transaction applies active range loss/retry, passive delivery audit, or
unattributable loss audit plus generation fencing and scheduler reconciliation
intent; the actual scheduling follows later from that committed intent.
Only adjacent applied intervals advance the source prefix. One persisted signed
completion retains its original root, applied prefix, timestamp and signature.
Later queries return that same evidence rather than reconstructing it.

### Give recovery delivery its own bounded, non-expiring queue

**Verdict: sound; high confidence.**

Recovery controls use the existing provenance and ledger pipeline with a dedicated
WorkQueue stream and durable consumer. MaxAge is zero, storage is finite and
DiscardNew preserves pending evidence through capacity refusal. Pending repair has
no delivery-count terminal path into the ordinary DLQ. Runtime startup rejects
unsafe overrides; code defaults and runtime settings apply beyond Helm.

Ordinary signed sessions read consumer coverage for their exact authenticated
source generation from core. The answer expires five seconds after request start,
and its deadline follows queued publication through provisional publisher handoff.
A fence, coverage beyond the ordinary session prefix, failed lookup or expired
answer closes the session retryably without manufacturing an ordinary ACK.
New known-unpublished credit is released on cancellation; uncertain rearmed credit
remains retained. This uses the existing publisher ownership contract.
