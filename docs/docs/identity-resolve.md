---
sidebar_position: 89
title: Resolve a Device Identity
---

# Resolve a Device Identity

Turn an address into the canonical `sr:` device UID, without probing the
device.

Several APIs are addressed by UID — the [Device Facts
API](./device-facts.md) among them — while the caller often knows only an
IP. This endpoint bridges that gap on its own. Resolution also happens
inside [Composite Check Validation
Runs](./validation-runs.md), but a validation run additionally re-probes
the device from every vantage-point agent on a named check. Use this when
you want the identifier and not the scan.

The IP is authoritative. An optional MAC corroborates it: a MAC that no
device holds is ignored, and a MAC held by a different device is reported
as a conflict rather than used as a tiebreak. No identity is ever created.

## Resolve one address

```
GET /api/v1/identity/resolve?ip=192.168.1.55&partition=default
Authorization: Bearer $SERVICERADAR_API_TOKEN
```

`partition` defaults to `default`. `mac` is optional.

```json
{
  "data": {
    "ip": "192.168.1.55",
    "partition": "default",
    "uid": "sr:8cad4cc3-e9f8-4873-a1fe-cf2529b246a0"
  }
}
```

| Status | `error` | Meaning |
| --- | --- | --- |
| 200 | — | Resolved |
| 400 | `missing_ip` | No address was supplied |
| 400 | `invalid_ip` | The value is not a valid address |
| 404 | `not_found` | No device holds that address |
| 409 | `ambiguous` | More than one device holds it; `uids` lists them |
| 409 | `mac_ip_conflict` | The MAC belongs to another device; `ip_uid` and `mac_uid` name both |

Ambiguity and a MAC/IP conflict are answers, not faults. An inventory that
reconciles identity continuously can hold both states, and each names the
devices involved so a caller can report which ones disagree.

## Resolve a batch

```
POST /api/v1/identity/resolve
Authorization: Bearer $SERVICERADAR_API_TOKEN
Content-Type: application/json
```

The same `devices` shape validation runs accept, with the same limit of
128 per request:

```json
{
  "partition": "default",
  "devices": [
    {"ip": "192.168.1.55"},
    {"ip": "192.168.1.103"}
  ]
}
```

A batch returns `200` and reports each address separately. One address
that cannot be resolved does not fail the request — a caller resolving a
long list still needs the entries that worked:

```json
{
  "data": [
    {"ip": "192.168.1.55", "partition": "default",
     "uid": "sr:8cad4cc3-e9f8-4873-a1fe-cf2529b246a0"},
    {"ip": "192.168.1.103", "partition": "default", "error": "not_found"}
  ]
}
```

Every entry echoes the address it is for, so results can be matched to the
request without relying on ordering. A per-device `partition` overrides the
top-level one.

The request itself is rejected with `400` when the list is empty
(`empty_devices`) or longer than 128 (`too_many_devices`).

## Authorization

Requires the `identity.resolve` permission, which is separate from
`validation_runs.execute`: a caller that needs an identifier does not need
the right to start probes across a fleet. It reveals less than viewing the
device inventory does, and defaults to the same roles.
