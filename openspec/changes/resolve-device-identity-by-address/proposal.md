## Why

`ServiceRadar.Inventory.Identity.ResolveByAddress` answers "which device is at this
address" and has no way to be asked.

It resolves IP plus partition to a `sr:` uid, corroborates an optional MAC, treats a MAC
pointing at a different device as a conflict, and never mints a uid. It is careful,
already authorized through an Ash actor, and reachable only as a side effect of
`POST /api/v1/validation-runs`.

That route does much more than resolve. It requires a composite check by name, re-probes
each resolved device from every vantage-point agent on that check, and starts an
evaluation. A caller that wants an identifier and nothing else has to name a check it has
no interest in and cause a real scan of real hardware to get one.

The callers who need this are the ones already told to use uids. `PATCH
/api/devices/{uid}/metadata` takes a uid the caller is expected to have. The device facts
guide says to write facts "as soon as the create response returns a UID" -- that is, to
start a validation run in order to learn the uid you need before you can write a fact.
Anything that knows a device by address and wants to say something about it is routed
through a probe.

More is coming that has the same need and less business starting one. A telemetry producer
attributing a log to a device knows an address; so does anything reporting an observation
about a host it just touched. Each of those wants one cheap read of an identity that
already exists.

## What Changes

- Expose the existing address resolver as a read of its own, at
  `GET /api/v1/identity/resolve` for a single address and `POST /api/v1/identity/resolve`
  for a batch.
- Report not-found, ambiguity, and a MAC/IP conflict distinctly, because a caller can act
  on each differently and none of them is a server error.
- Give it its own RBAC key, so reading an identity does not require permission to execute
  a validation run.
- Document it as the way to obtain a uid, and correct the device-facts guidance that
  currently sends callers through a validation run to get one.

## Impact

- Affected specs: `device-inventory`
- Affected code: `elixir/web-ng` router and a new controller; `catalog.ex` for the
  permission key; `docs/docs/nco-device-facts.md`
- No change to `ResolveByAddress` itself, to validation runs, or to any existing route
