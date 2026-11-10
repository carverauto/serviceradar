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
