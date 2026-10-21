---
sidebar_position: 91
title: Device Source Facts API
---

# Device Source Facts API

ServiceRadar keeps a device's switch port and VLAN as source facts. Each source
that knows them reports its own value, ServiceRadar compares the values, and the
winner becomes the device's canonical `switch_port_attachment` and `vlan_uid`.
Built-in integrations and inventory plugins already report these facts. This
API lets a system outside ServiceRadar report them too, so its evidence is
compared, promoted, and checked for disagreement in the same way.

This is not the [Device Facts API](./device-facts.md). That API stores scalar
values for composite checks, and it rejects `switch_port_attachment`.

Devices are addressed by their canonical `sr:` uid. A caller that knows only an
address can obtain one with [Resolve a Device Identity](./identity-resolve.md).

## Report a fact

```
PUT /api/devices/:uid/source-facts/:fact_key
```

`fact_key` is `switch_port_attachment` or `vlan_uid`.

Request body:

```json
{
  "source": "example-nms",
  "value": {
    "switch_hostname": "access01.example.com",
    "port": "Gi1/0/7",
    "vlan_id": "120"
  }
}
```

For `switch_port_attachment`, `switch_hostname` and `port` are required.
`if_alias`, `vlan_id` (1 to 4094), `vlan_name`, `switch_device_uid`, and `raw`
are optional. The value may also be a string of the form
`"<switch-hostname>:<port>"`. Each field may be up to 255 bytes, and `raw` up to
512.

For `vlan_uid`, the value is a VLAN id from 1 to 4094, as a number or a string.

Response:

```json
{
  "data": {
    "uid": "sr:7c1e4b2a-9d3f-4e8a-b6c5-2f1a0e9d8c7b",
    "fact_key": "switch_port_attachment",
    "source": "api:example-nms",
    "source_instance": "user:3f2b8c1d-aa4e-4b7f-9c2d-5e6f7a8b9c0d",
    "reported": {
      "value": {
        "switch_hostname": "access01.example.com",
        "port": "Gi1/0/7",
        "vlan_id": "120",
        "raw": "access01.example.com:Gi1/0/7"
      },
      "present": true,
      "observed_at": "2026-10-21T12:00:00.000000Z"
    },
    "canonical": {
      "switch_hostname": "access01.example.com",
      "port": "Gi1/0/7",
      "vlan_id": "120",
      "raw": "access01.example.com:Gi1/0/7",
      "source": "api:example-nms",
      "source_instance": "user:3f2b8c1d-aa4e-4b7f-9c2d-5e6f7a8b9c0d",
      "observed_at": "2026-10-21T12:00:00.000000Z"
    },
    "disagreement_open": false
  }
}
```

`reported` is your value as ServiceRadar recorded it. `canonical` is the
device's value for that key after reconciliation, which can come from another
source. Reporting the same key again replaces your previous value.

## Withdraw a fact

```
DELETE /api/devices/:uid/source-facts/:fact_key?source=example-nms
```

A reported fact does not expire. Withdraw it as soon as you can no longer
observe it. If the withdrawn value is the device's canonical value and no other
present source reports it, the canonical value is cleared. Withdrawing a fact
you never reported, or already withdrew, returns 200 and changes nothing.

## Sources and callers

- `source` names the system that is reporting: a lowercase letter followed by up
  to 62 lowercase letters, digits, `-`, or `_`. ServiceRadar records it as
  `api:<source>`, so a reported fact can never be mistaken for one from a
  built-in integration or plugin.
- The source instance is the caller: `user:<id>` for the user that a session,
  API token, or OAuth client acts for. A caller cannot replace or withdraw
  another caller's facts, even under the same `source`.
- `observed_at` is stamped by the server.

## How a reported value is used

ServiceRadar normalizes the value (switch hostname and port compare
case-insensitively) and compares it with every other present source for the
same device and key:

- If yours is the only source, or every source agrees, the value becomes
  canonical.
- If sources disagree, ServiceRadar opens a disagreement and emits an event. If
  an operator has made one integration or plugin assignment authoritative for
  that fact, its value wins. Otherwise the current canonical value is kept.
  Open disagreements are listed by `in:source_fact_disagreements`.
- An API source cannot be made authoritative.

## Authorization

The caller needs `devices.view` to address the device and
`devices.source_facts.write` to report or withdraw a fact. The operator and
admin roles have both by default. `devices.source_facts.write` is separate from
`devices.facts.write` and `devices.update`, because a reported switch port can
become the device's canonical attachment.

## Errors

| Status | Meaning |
| --- | --- |
| 400 | `source` or `value` is missing, or the uid is malformed |
| 403 | caller lacks `devices.source_facts.write` |
| 404 | no device with that uid is visible to the caller |
| 422 | unknown fact key, an invalid `source`, or a value that cannot be read |
