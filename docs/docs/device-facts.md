---
sidebar_position: 90
title: Device Facts API
---

# Device Facts API

External tools write boolean and other scalar facts onto a device through
this endpoint. Composite service checks consume these facts as
`device_metadata` inputs, so a fact written here can take part in a
verdict such as "isolation is observed AND the access-control
configuration that enforces it is applied".

This endpoint is addressed by the canonical `sr:` device UID. A caller that
knows only an address can obtain one with [Resolve a Device
Identity](./identity-resolve.md).

After writing facts, kick a targeted re-probe and read that verdict
through [Composite Check Validation Runs](./validation-runs.md).

## Endpoint

```
PATCH /api/devices/:uid/metadata
```

Request body:

```json
{
  "facts": {
    "acl_enforced": true
  }
}
```

Response:

```json
{
  "data": {
    "uid": "sr:9f0c...",
    "facts": {
      "acl_enforced": {
        "value": true,
        "source": "automation-bot",
        "updated_at": "2026-08-12T15:04:05.123456Z"
      }
    }
  }
}
```

Only externally written facts are echoed back, not the device's whole
metadata map.

## Authorization

The caller needs the `devices.facts.write` permission. It is deliberately
separate from `devices.update`: a validation tool should be able to set a
boolean without also being able to rename, retag, or reassign the device.
Grant it to a dedicated service account rather than reusing an operator
login.

## What you can write

- Keys must match `^[a-z][a-z0-9_]{0,63}$`.
- Values must be scalars: boolean, number, or string.
- At most 32 externally written facts per device. Overwriting a fact you
  already wrote does not count against the cap.
- Keys reserved for internal enrichment are rejected, including
  `passive_fingerprint`, `identity_state`, `identity_source`, and
  `__fact_provenance`.

If any fact in a request is invalid, the whole request is rejected and
nothing is written. A partial write would leave the caller believing
every fact landed.

## Provenance and freshness

Alongside the plain value, the server records who wrote the fact and
when, under the `__fact_provenance` metadata key. This is stamped
server-side; a timestamp supplied in the request body is ignored, so a
fact cannot be back-dated.

This matters for composite checks. A `device_metadata` input may declare
a `max_age`, and a fact older than that resolves as `unknown` rather than
as its stored value, which normally sends the device's verdict to
`inconclusive`.

Re-write a fact at least once per configured `max_age` window even when
the value has not changed. A fact written once and never refreshed will
age out and stop contributing to verdicts.

If an input declares no `max_age`, the stored value is used regardless of
age and no provenance is required. That keeps metadata keys written by
paths which do not record provenance usable as inputs.

## Errors

| Status | Meaning |
| --- | --- |
| 400 | `facts` missing, empty, or not an object |
| 403 | caller lacks `devices.facts.write` |
| 404 | no device with that uid |
| 422 | a fact violated the key pattern, value type, reserved-key list, or the per-device cap |
