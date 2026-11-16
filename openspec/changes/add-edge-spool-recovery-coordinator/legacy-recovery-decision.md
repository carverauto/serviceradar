# Legacy recovery scope decision

Status: approved by the product owner on 2026-11-09. Automatic recovery applies
only to new bounded attributed generations. Legacy compatibility is out of scope.

The owner approved bounded recovery first, then directed that no time be spent
supporting legacy storage. Do not build legacy migration, a legacy drain path,
copy-only recovery controls or a source aggregation protocol for old flat files.

Existing files remain untouched, accounted against the storage budget and visible
as unsupported retained storage. Retention is required by the no-data-loss rule;
it is not a claim that their old sequence gap or capacity problem is repaired.
New production uses the bounded attributed format when capacity permits.

## Why the boundary is explicit

New generation admission budgets 320 worst-case manifest bytes per attributed
allocation plus page overhead before append, fitting at most 817 attributed
allocations into four pages and 256 KiB. Independent slot and byte caps also apply.

Old flat storage lacks these generation bounds. A synthetic source with 2500
intact records before a gap needs copy-only chunks, which the existing nonempty
loss-manifest grammar cannot represent. It also lacks independently persisted
scope, agent and lane identity for unreadable slots. Current configuration does
not establish that historical identity.

These are reasons to leave the old format unsupported, not requirements to build
another protocol. The approved Decisions 1-5 and their deletion gates remain
unchanged for new bounded generations.

## Amendment: drained flat storage is retired (2026-11-15)

The product owner reversed part of this decision on 2026-11-15. The governing
rule is that no undelivered record may be lost, and keeping storage that
provably holds no record served no part of it: it only marked every upgraded
agent's edge pipeline not ready for good.

Upgraded agents showed two cases. Most retained exactly the old sender's
metadata after a full drain: the segment pointer, the resolved watermark, the
spool id, a reclaim checkpoint and an empty reclaimed segment, with no commit
evidence. A few retained a short tail of committed records: the update stopped
the old agent seconds after it appended them and before its next drain pass.

The agent now inspects flat storage read-only at open. It removes the storage,
with an audit log line, only when every segment and both evidence copies are
empty and every root entry belongs to the flat layout. Anything else is kept
untouched, charged and reported as before. The removal takes the segment
pointer before the data it names, so an interrupted removal is still recognized
as drained and finished on the next start.

Re-delivering a retained tail is not part of this amendment. Admission into a
bounded lane validates a record's production authority and fence at the time of
admission. A tail written days earlier fails that check, because its production
capability has expired and its fence is stale. Delivering it needs a rule for
judging authority at production time. That rule is a separate decision; until
it is made, such a tail stays retained and reported. Draining before the
update stops the old agent cannot be added either. The stopping is done by the
old agent and the package-installed updater already on the host, and new code
reaches neither. Lane storage persists across restarts, so the stranding is
specific to the move from flat storage to lanes.

## Amendment: retained tails are handed off (2026-11-15)

The product owner directed that no record captured at the edge may be left
stranded. The production-time admission rule in
[add-edge-production-time-admission](../add-edge-production-time-admission/design.md)
supplies what this decision lacked: committed records in the pre-lane flat spool
are handed off, in order, to a late generation and judged by core against the
authority that was valid when they were produced. The flat spool is then retired
through the same structural emptiness proof. This is late admission, not a
recovery operation; Decisions 1-5 are unchanged. Only root entries no known
layout accounts for stay retained and reported as unsupported.
