---
sidebar_position: 10.5
title: Group Permission Mapping
---

# Group Permission Mapping

Mapping rules turn claims from your identity provider into ServiceRadar access.
They are configured in **Settings -> Authorization** with one row per match
(not by editing JSON) and applied on every SSO sign-in, so directory changes
take effect the next time a user signs in rather than when an operator
remembers to mirror them.

## Built-in roles versus role profiles

These are different things, and the default-role dropdown only lists the first.

| Kind | Built-in role | Role profile |
| --- | --- | --- |
| What it is | One of four rungs: `viewer`, `helpdesk`, `operator`, `admin` | A named permission set, for example `demo` or Plugin Authors |
| Where you edit it | You cannot. The rungs are fixed. | **Settings -> Policy Editor** |
| Where you grant it from SSO | Mapping row -> **Built-in role** | Mapping row -> **Role profile** |
| When to use it | The person should have that whole rung | The team should get a specific capability without becoming `operator` |

`demo` is a role profile, not a built-in role. To give an IdP group the `demo`
profile: **Add mapping** -> source `IdP group` -> paste the group name (Authentik)
or object ID (Entra) -> **Role profile** -> `demo`. Leave **Built-in role** on
None unless they also need a rung on that ladder. Keep `plugins.view`,
`settings.api_credentials.manage`, and `settings.mcp.manage` off that profile
unless the demo account should see Dashboard Packages, Edge Ops add-ons, API
credentials, or MCP.

A mapping can grant a role, a profile, a ServiceRadar user group, or any
combination. You do not paste UUIDs; the profile and user-group fields are
dropdowns of names.

## Creating Accounts On First SSO Login

By default an identity-provider user with no local ServiceRadar account is
denied. That is the safe default: SSO success at the IdP is not enough to mint
an account.

Turn on **Create accounts on first SSO login** in **Settings -> Authorization**
(the same switch as **Settings -> Authentication -> Auto-provision Accounts**)
when you want the first successful SSO sign-in to create the local account.
The new account gets the configured default role unless a mapping grants a
higher role, a role profile, or a user group.

Use this for a first production SSO cutover when you do not want to pre-create
dozens of local users. Gate who can authenticate at the IdP (app assignment /
group) so that only people you intend to onboard can complete the login.

## Adding A Mapping

In **Settings -> Authorization**:

1. **Add mapping**.
2. Choose what to match: IdP group (usual), email domain, email address, or a
   named claim.
3. Enter the value. For Authentik that is the group name. For Entra it is the
   group object ID unless you configured names.
4. Grant at least one of: a built-in role, a role profile, a user group.
5. Save, then dry-run a sample claim set before trusting it in production.

Prefer a profile over a role when the intent is "this team may do this one
thing". Reaching for `operator` because a permission happens to sit inside it
grants the rest of `operator` too.

## Match Sources

| Source in the UI | Stored as | Matches against |
| --- | --- | --- |
| IdP group | `groups` | An entry in the group claim |
| Email domain | `email_domain` | The domain part of the user's email |
| Email address | `email` | The full email address |
| Named claim | `claim` | The value of a named claim |

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

Entra does **not** have a `groups` OIDC scope. Membership is added under
**Token configuration -> groups claim**, and then the ID token (and optionally
the access token) carries a `groups` claim. Requesting `scope=groups` is an
Authentik/Keycloak convention; Entra ignores it. If a `groups`-source mapping
exists, **Settings -> Authorization** warns about both cases: a missing
Authentik-style scope, and Entra's object-ID / overage behaviour.

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
3. **Add the mapping.** In **Settings -> Authorization**, **Add mapping**,
   source `IdP group`, value that object ID, **Role profile** `Plugin Authors`.
   Leave the built-in role on None -- the user keeps the default role, plus
   this one capability.
4. **Dry-run it.** Paste a claim set containing that object ID and confirm the
   profile is listed and the mapping is shown as matched.
5. **Verify by signing in.** The user's next sign-in applies the profile; they
   can then authenticate the CLI and publish. Removing them from the Entra
   group revokes the profile at their next sign-in.
