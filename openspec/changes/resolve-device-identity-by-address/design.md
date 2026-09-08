## Context

`ResolveByAddress.resolve/1` takes `%{ip:, partition:, mac:, actor:}` and returns
`{:ok, uid}` or one of four errors: `:not_found`, `:invalid_ip`, `{:ambiguous, uids}`,
`{:mac_ip_conflict, ip_uid, mac_uid}`. IP is authoritative; a MAC absent from inventory is
ignored, and a MAC pointing elsewhere is a conflict rather than a tiebreak.

Its one caller is `Validation.Orchestrator`, which resolves each target before probing it.
The module is complete. This change is a route, a controller action, and a permission key.

## Goals / Non-Goals

- Goals
  - Obtaining a uid costs one read and no side effects.
  - The four outcomes stay distinguishable at the HTTP boundary.
  - Reading an identity is a lesser permission than executing a validation run.
- Non-Goals
  - Changing resolution semantics. The module's judgment is the contract; this exposes it
    unaltered.
  - Resolving by hostname. Hostnames are not unique across partitions in the way an
    address is, and no caller has asked.
  - Creating a device. `ResolveByAddress` never mints a uid, and neither does this.

## Decisions

### Decision: `/api/v1/identity/resolve`, not `/api/devices/resolve`
The device routes are a browse of the inventory: list, show, export, patch metadata. They
are addressed by uid because the uid is what identifies a device. This is the operation
that runs *before* a caller can use any of them, and it is addressed by something that is
not an identity yet.

`identity` also matches where the code lives -- `Inventory.Identity` -- and sits beside
`validation-runs`, the versioned surface these callers already speak. And `/api/devices/`
plus a non-uid segment invites the reading that `resolve` is a device named "resolve".

### Decision: Both a single read and a batch
`GET /api/v1/identity/resolve?ip=&partition=&mac=` is the natural shape: a read, cacheable,
trivially callable from a shell while debugging, and the shape a caller resolving one
device at a time wants.

`POST /api/v1/identity/resolve` takes the same `devices` list `validation-runs` already
accepts, so a caller that resolves a deployment's worth of switches makes one request
instead of forty. Reusing that request shape means a caller already speaking to
validation-runs does not learn a second vocabulary for the same thing.

The batch is not a GET with repeated parameters: the list is unbounded in principle, and a
URL is the wrong place for it.

- Alternatives considered:
  - **Batch only.** One shape to document, and it makes the common single lookup a POST
    with a body, which is neither cacheable nor convenient.
  - **Single only.** Forty round trips to resolve a deployment, every one of them a
    database read that could have been one query.

### Decision: The batch reports per-device outcomes and stays 200
A batch where one address is unknown is not a failed request. Each entry carries either a
uid or a reason, and the response is 200 as long as the request itself was well formed.
A caller resolving forty switches needs the thirty-nine that worked.

The single read does use status codes, because there is exactly one outcome to report:
200 with the uid, 400 for an unparseable address, 404 for not found, 409 for ambiguity or
a MAC/IP conflict.

### Decision: A malformed entry fails the request; an unresolvable one does not
These look alike and are not. An address that resolves to nothing is an answer about the
inventory, and belongs in its slot beside the ones that did resolve. An entry carrying no
address at all is a broken request: `ip` is required per entry in the published schema,
and there is no address to report an outcome for.

Dropping such an entry -- the first implementation did -- returns fewer results than
addresses submitted, which quietly breaks the guarantee that every entry can be matched to
its input, and hides the caller's bug behind a shorter list.

### Decision: Ambiguity and conflict are answers, not failures
Two devices claiming an address, or a MAC that points somewhere else, are real conditions
in an inventory that reconciles identity continuously. Flattening them to "not found"
would make a caller retry forever; flattening them to a 500 would page somebody.

Both report the candidate uids, so the caller can say which devices are in conflict rather
than only that something is. That is not a leak: a caller permitted to resolve an address
is permitted to learn the devices at it.

Ambiguity turns out to be unreachable today, which was discovered by trying to test it:
`ocsf_devices_unique_active_ip_idx` makes an active device's address unique, and
`DeviceIdentifier` is unique per type, value and partition, so neither branch that returns
it can fire. It stays handled. The resolver declares the outcome, a schema constraint is
not the contract, and relaxing that index later should not convert a documented answer
into a 500.

### Decision: Its own permission key
`validation_runs.execute` currently gates the only path to a resolution, and it should not
be what a caller needs to look up an id. Reading an identity is closer to reading the
device inventory than to launching probes across a fleet, and a telemetry producer that
should never start a validation run will need exactly this.

So `identity.resolve`, in the `devices` section of the catalog beside `devices.facts.write`.

It defaults to the same roles as `devices.view`, which is every role. That looked wrong
until the two were compared: `devices.view` lists the whole inventory with each device's
address and uid, so anyone holding it can already build this mapping by hand. Resolving one
address returns strictly less than that. Withholding it by default would not protect
anything, and would leave the endpoint unusable until someone hand-granted a permission
weaker than one they already had.

The separation that matters is from `validation_runs.execute`, and that is kept: a caller
may resolve without being able to start probes across a fleet.

## Risks / Trade-offs

- **A cheap endpoint is a cheap way to probe which addresses exist.** True of
  `GET /api/devices` already, and this returns strictly less. → RBAC-gated like every other
  inventory read.
- **Two routes to the same resolution.** Validation runs keep resolving internally rather
  than calling out over HTTP; the duplication is a second door, not a second implementation.
- **Callers may batch enormous lists.** → Bound the batch and reject an over-long one
  explicitly, rather than letting it become a slow query.

## Open Questions

- What is the batch bound? `validation-runs` has an effective limit in what a probe
  deadline allows; a pure resolve has no such natural ceiling. Proposed: a few hundred,
  named in the error when exceeded.
- Should the response carry anything beside the uid -- hostname, partition, live state? A
  caller wanting more can follow with `GET /api/devices/{uid}`. Proposed: uid only, and
  echo the input so a batch response can be correlated to its request.
