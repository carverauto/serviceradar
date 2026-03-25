## Context
Analysis dispatch is now proven through normalized relay-scoped contracts, but worker targeting is still too static. For production use, the platform needs to know which workers exist, what they support, and how to select one for a given branch.

The registry should stay platform-owned. Workers may advertise capabilities or be configured with them, but `core-elx` remains the owner of branch lifecycle, dispatch, and result ingestion.

## Goals
- Add a platform-owned registry of camera analysis workers.
- Allow relay analysis branches to select a worker by explicit id or by capability.
- Preserve relay session, branch, and worker provenance end to end.
- Make unavailable or mismatched workers observable.

## Non-Goals
- Replacing the normalized result contract.
- Replacing the existing analysis dispatch manager.
- Adding dynamic service discovery for every possible worker runtime in this change.

## Decisions
### Keep worker registration explicit
The first registry path should use explicit registration/configuration rather than open-ended discovery. That keeps operator intent and failure modes clear.

### Keep selection narrow
The first selection model should support explicit worker id and simple capability matching. More advanced scheduling can come later.

### Keep dispatch adapter-specific
The registry decides *which* worker to use. The existing dispatch managers and adapters still decide *how* to send bounded media and ingest results.

## Risks
### Registry state can drift from reality
Workers can be registered but unhealthy. The registry must make health and availability visible to operators.

### Selection logic can become a scheduler too early
If worker matching becomes too complex in the first slice, the platform will gain implicit scheduling behavior without enough operational feedback.

### Provenance can be lost at selection time
If worker identity is resolved too late or outside the platform boundary, results may lose the originating worker reference. Selection must remain explicit in the platform.
