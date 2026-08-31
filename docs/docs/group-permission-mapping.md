---
sidebar_position: 10.5
title: Group Permission Mapping
---

# Group Permission Mapping

Mapping rules turn claims from your identity provider into ServiceRadar access.
They are configured in **Settings -> Authorization** and applied on every SSO
sign-in, so directory changes take effect the next time a user signs in rather
than when an operator remembers to mirror them.

## What A Mapping Can Grant

A mapping matches on a claim and grants one or more of:

- **A role.** One of `viewer`, `helpdesk`, `operator`, `admin`. Roles are coarse
  and built in; they cannot be edited.
- **A role profile.** A named permission set from **Settings -> Auth -> Role
  Profiles**. This is how a group grants a specific capability, such as staging
  a plugin, without also granting everything else an `operator` can do.
- **A user group.** A ServiceRadar group. Group membership backs dashboard
  sharing and device group grants, so this keeps an IdP group and the
  ServiceRadar group of the same name from drifting apart.

Prefer a profile over a role when the intent is "this team may do this one
thing". Reaching for `operator` because a permission happens to sit inside it
grants the rest of `operator` too.

## Match Sources

| Source         | Matches against                                  |
| -------------- | ------------------------------------------------ |
| `groups`       | An entry in the group claim                      |
| `email_domain` | The domain part of the user's email              |
| `claim`        | The value of a named claim                       |

`claim` names the claim to read and supports dot-notation for nested values
(example: `user.department`).

## Precedence And Union

Every mapping that matches contributes. This matters when a user is in several
mapped groups:

- **Role profiles and user groups union.** All of them are collected.
- **The highest role wins.** Order is `viewer` < `helpdesk` < `operator` <
  `admin`, so a user matching both a `helpdesk` and an `operator` mapping gets
  `operator`.
- **Mapping order does not matter.** Reordering the list does not change what a
  given claim set resolves to.
- **No match falls back to the configured default role** and grants no profile
  or group.

A user carries a single role profile, so if several profile-granting mappings
match, the first is applied and the rest are logged as ignored. Bind a team to
one profile rather than relying on several to combine.

## Revocation

Removing a user from a mapped group revokes what that group granted, at their
next sign-in. Grants record where they came from, and revocation only touches
IdP-sourced ones:

- A role profile assigned by an operator in the UI is never revoked by a claim
  change.
- A group membership added by an operator is never withdrawn by a claim change.

This is deliberate. Clearing every profile that no mapping accounted for would
strip access from users who have no mapping at all, which is most of them.

Revocation is recorded as a `role_mapping` authentication event, alongside the
grants that were applied and which mappings matched. Claim payloads are not
recorded: a claim set carries far more about a person than the decision needs.

## Testing A Mapping Before You Trust It

**Settings -> Authorization** has a dry-run resolver. Paste a claim set and it
shows the resolved role, the profiles and groups it would grant, and which
mappings matched -- without signing in as anybody.

Use it whenever a mapping does not appear to do anything. The usual cause is
that the claim never arrived, not that the mapping is wrong.

## Microsoft Entra ID

### Emitting The Groups Claim

Entra does not send group membership by default. In the app registration, under
**Token configuration**, add a **groups claim** and choose which groups to emit
(security groups, or groups assigned to the application). Choosing "Groups
assigned to the application" keeps the claim small, which matters -- see
overage below.

Also confirm the `groups` scope is included in the configured OIDC scopes in
ServiceRadar. If a `groups`-source mapping exists while the scope is missing,
the mapping matches nothing; **Settings -> Authorization** warns when it detects
this, because an unscoped mapping looks identical to a broken one.

### The Claim Carries Object IDs, Not Names

By default the `groups` claim contains group **object IDs** (GUIDs), not display
names:

```
"groups": ["7c2f5b8e-1d4a-4f6b-9c3e-2a8d5f1b6e40"]
```

So a mapping with `value` set to `Network Operations` will not match. Use the
object ID as the value, or configure the app registration to emit group names
instead (**Token configuration -> groups claim -> Emit groups as role claims**,
or the `cloud_displayname` option for synced groups). Object IDs are stable
across renames, which is usually what you want for an access grant; names are
easier to audit. Pick one and be consistent.

Copy a group's object ID from **Entra admin center -> Groups -> (group) ->
Overview -> Object ID**.

### Group Overage

If a user is a member of more than roughly 150 groups (200 for SAML), Entra
omits the `groups` claim entirely and sends a Graph API pointer instead:

```
"_claim_names": { "groups": "src1" },
"_claim_sources": { "src1": { "endpoint": "https://graph.microsoft.com/..." } }
```

ServiceRadar does not follow that pointer, so **every groups mapping stops
matching for that user** and they fall back to the default role. This is easy
to miss: it affects only the users in many groups, so most sign-ins keep
working.

Avoid it by emitting only groups assigned to the application rather than all
security groups. If a user reports losing access after a directory change while
everyone else is fine, check for overage first.

## Worked Example: Granting Plugin Publishing To A Team

Goal: members of an Entra group may stage WASM plugins, and nothing else.

1. **Create the profile.** In **Settings -> Auth -> Role Profiles**, create
   `Plugin Authors` with `plugins.view` and `plugins.stage`. Both are needed:
   `plugins.stage` uploads a package, `plugins.view` is what lets the author see
   it afterwards. Do not add `plugins.approve` -- staging and approving are
   separate permissions so that the person publishing a plugin is not also the
   person clearing it for use.
2. **Get the group's object ID.** In the Entra admin center, open the group and
   copy its Object ID.
3. **Add the mapping.** In **Settings -> Authorization**, add an entry whose
   source is `groups`, whose value is that object ID, and which grants the
   `Plugin Authors` profile. Do not also grant a role -- the user keeps the
   default role, plus this one capability.
4. **Dry-run it.** Paste a claim set containing that object ID and confirm the
   profile is listed and the mapping is shown as matched.
5. **Verify by signing in.** The user's next sign-in applies the profile; they
   can then authenticate the CLI and publish. Removing them from the Entra
   group revokes the profile at their next sign-in.
