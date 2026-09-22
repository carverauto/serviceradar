---
title: Roles & Permissions
---

# Roles & Permissions

ServiceRadar uses role-based access control (RBAC) to decide what each signed-in
user can see and do. Every user is assigned a **role**, and every role grants a
set of **permissions** drawn from a fixed permission catalog. Administrators can
also create **custom role profiles** for individual users or reusable user
groups. Effective permissions combine one base profile with the profiles from
all current group memberships.

This page is for operators and administrators who manage who can do what. For how users sign in (local passwords, OIDC, SAML), see
[Authentication](./auth-configuration.md). For mapping identity-provider
groups onto these roles and profiles, see
[Group Permission Mapping](./group-permission-mapping.md).

## The four built-in roles

ServiceRadar ships with four built-in roles. Each is progressively more
privileged: `admin` can do everything `operator` can, `operator` can do
everything `helpdesk` can, and so on.

| Role | Intended for | What it can do |
| --- | --- | --- |
| `viewer` | Read-only stakeholders | View dashboards, devices, services, observability data (logs, metrics, traces, events, NetFlow, alerts), rules, the playbook catalog, Ansible operation history, and northbound action history. Export device inventory and view its own CLI sessions. Cannot change anything. |
| `helpdesk` | First-line responders | Everything a `viewer` can do, **plus** acknowledge and resolve alerts. |
| `operator` | Day-to-day operations staff | Everything `helpdesk` can do, **plus** create and update devices, services, observability rules, sweep groups, integrations, SNMP/Sysmon profiles, and NetFlow settings. Run sweeps, discovery, services, reviewed Ansible playbooks, and northbound actions. View settings pages and the audit/security event stream. Operators generally cannot perform destructive auth/security actions or manage RBAC. |
| `admin` | Platform administrators | Full access. Everything `operator` can do, **plus** manage users, roles, and auth settings; manage RBAC role profiles; manage credentials, outbound mail, plugins, edge packages, jobs, remote-access targets and host keys; approve plugin packages and northbound providers; open and review remote-access sessions; and manage audit/security state. |

Permissions below are the building blocks for built-in roles and custom role
profiles. The effective base and group-profile rules are described below.

## The permission catalog

Internally, access is enforced through a canonical **permission catalog**.
Permissions are grouped by functional area, and each permission declares its
**default roles** — the built-in roles that receive it out of the box.

The catalog covers these areas:

| Area | Examples of what it controls |
| --- | --- |
| **Analytics** | Viewing analytics dashboards; managing saved queries. |
| **Devices** | Viewing, creating, updating, bulk-editing, importing/exporting, and deleting devices; opening device consoles; all SSH/RDP/app/TCP remote-access actions, recordings, and file transfers. |
| **Services** | Viewing, creating, updating, deleting, and running service checks. |
| **Observability** | Viewing logs, metrics, traces, events, NetFlow, and alerts; creating/updating/deleting observability rules; acknowledging and resolving alerts. |
| **Settings** | Viewing settings; managing users and auth; changing own local password; managing personal API credentials and MCP access; managing RBAC; managing networks, NetFlow, integrations, credentials, outbound mail (`settings.mail.manage`), SNMP/Sysmon profiles, [visibility profiles](./visibility-profiles.md), jobs, plugins, edge packages, remote-access host keys and targets; viewing and managing the audit/security state. See [Outbound Mail](./outbound-mail.md). |
| **Plugins** | Viewing, staging, approving, and assigning plugin packages. |
| **Ansible** | Viewing/managing AWX controllers and playbook repositories; viewing canonical operation history; launching reviewed playbooks; authorizing operation cancellation. Reserved schedule keys expose no workflow. |
| **Northbound Actions** | Viewing, managing, launching, and cancelling provider-neutral northbound actions; managing event handlers. |
| **Network Ops** | Triggering on-demand sweeps and discovery jobs. |
| **CLI Sessions** | Approving CLI device authorizations; viewing and revoking your own (or any) CLI sessions; managing CLI auth policy. |
| **Dashboards** | Publishing, enabling, and disabling dashboard packages via the API. |

As a rule of thumb:

- **View** permissions default to all four roles.
- **Create/update/run** permissions default to `operator` and `admin`.
- **Acknowledge/resolve alerts** defaults to `helpdesk`, `operator`, and `admin`.
- **Destructive, security-sensitive, and administrative** permissions
  (user management, RBAC, credentials, plugin approval, remote access, audit
  state, CLI policy) default to `admin` only.

### SRQL and detail-page access

SRQL queries require the effective view permission for the requested data
domain, including queries loaded by detail pages, pagination, related data,
and previews. Signing in or opening a direct detail URL does not grant access
to a domain omitted from the user's effective permissions. Related data can
require a different permission from the main record.

Gateway details require `devices.view` for both live registry information and
stored records. Users without it are redirected to the dashboard with a
permission error.

The entity-to-permission mapping and scope authorization contract are owned by
`ServiceRadarWebNG.SRQL.EntityAccess` in
`elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`.

## Custom role profiles

When the built-in roles do not match a team's needs, an administrator can create
a **custom role profile**: a named bundle of specific permission keys. A profile
assigned directly to a user becomes that user's base profile instead of the
system profile for their built-in role. If no direct profile is assigned, the
built-in role's system profile remains the base.

A reusable user group can also have one role profile. Every current membership
adds that group's profile permissions to the user's base permissions. Membership
in several profiled groups produces the set union of all those permissions, so a
permission granted through more than one profile has no additional effect. A
group profile augments the base profile; it does not replace it.

Users relying on a built-in profile get personal API credentials
(`settings.api_credentials.manage`) and MCP (`settings.mcp.manage`) because
those default to every role. Omit them on a directly assigned custom profile to
hide **Settings -> API Credentials**, **MCP Sessions**, and to refuse `/mcp`
and MCP OAuth consent. Omit `plugins.view` on the same profile to hide
**Dashboard Packages** and the Edge Ops add-on catalog.

The four built-in roles also exist as system role profiles (`Admin`,
`Operator`, `Helpdesk`, `Viewer`). System profiles cannot be edited or deleted;
custom profiles can.

### Managing role profiles in the UI

Role profiles are managed under **Settings → Auth/Users**:

- **Settings > Auth > RBAC** - browse the permission catalog and create, edit,
  or delete custom role profiles. Each profile is given a name, an optional
  description, and a checklist of permissions. The same page lists reusable
  user groups, where an administrator can assign or clear one group role profile.
- **Settings > Auth > Users** - view users and assign each user a role or a
  custom role profile.

Managing role profiles requires the **Manage RBAC policies**
(`settings.rbac.manage`) permission; managing users requires **Manage users and
auth** (`settings.auth.manage`). Loading group assignments also requires
`identity.user_groups.view`, and changing them requires
`identity.user_groups.manage`. The manage permissions default to `admin`;
group viewing defaults to `operator` and `admin`.

### Managing dashboard audiences for a group

From **Settings > Auth > RBAC**, select **Dashboards** beside a user group to
manage that group's explicit view grants. Authored dashboards and installed
dashboard packages are loaded and paged independently.

This surface is not an exclusive access list:

- A public authored dashboard is already available to users with analytics
  access, while a public packaged dashboard is available to authenticated users.
  Public rows are read-only here, and no redundant group grant is created.
- An explicit `view` grant can be added or removed. An existing `edit` grant is
  stronger, remains read-only in this editor, and is never downgraded or removed
  by the view control.
- Source-wide `view_all` permissions can grant access independently of the
  selected group's explicit grant.
- Granting group view to a private packaged dashboard also changes its visibility
  to shared. Removing that grant does not automatically make it private again.

Changing an authored dashboard audience requires `settings.rbac.manage`,
`analytics.dashboards.share`, and authority over that target as its owner,
through an explicit `edit` grant, or through `analytics.dashboards.edit`.
Changing a packaged dashboard audience similarly requires
`dashboards.packages.share` and target authority as owner, through an explicit
`edit` grant, or through `dashboards.packages.view_all`.

The editor reloads current server state before applying a change. If another
administrator or a dashboard-local sharing control changed the same row after it
was displayed, the stale operation is rejected and the affected list reloads.

### Managing role profiles via the API

Role profiles can also be managed programmatically through the admin API
(API key or bearer token, with the same RBAC permission required):

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/api/admin/role-profiles/catalog` | List the full permission catalog. |
| `GET` | `/api/admin/role-profiles` | List all role profiles. |
| `GET` | `/api/admin/role-profiles/:id` | Show one role profile. |
| `POST` | `/api/admin/role-profiles` | Create a custom role profile. |
| `PATCH` | `/api/admin/role-profiles/:id` | Update a custom role profile. |
| `DELETE` | `/api/admin/role-profiles/:id` | Delete a custom role profile. |

A create or update request supplies a `name`, an optional `description`, and a
`permissions` array of permission keys (for example `devices.view`,
`services.run`). Use the `catalog` endpoint to discover valid keys.

A user always has a built-in role (the rung) and may have a directly assigned
role profile. The direct profile replaces the built-in system profile as the
user's base; profiles assigned through current user-group memberships are then
added to that base. Mapping an IdP group onto a profile does **not** require
putting that profile in the default-role dropdown. That dropdown is only the
four built-in rungs. See
[Group Permission Mapping](./group-permission-mapping.md).

## How roles are assigned to users

Each user record carries a built-in role and, optionally, a direct role profile.
Assign or change those from **Settings > Auth > Users**, or let SSO apply them
from **Settings > Authorization** mappings on each sign-in. Assign a role
profile to a reusable user group from **Settings > Auth > RBAC**; every current
member receives that profile's permissions in addition to their base profile.

When a user's role, direct profile, group membership, group profile, or a
profile's permission list changes, ServiceRadar invalidates the affected RBAC
caches after the change commits. Sensitive operations reload the user's current
memberships and profiles instead of trusting permissions retained by an older
page or session. Removing or deleting a profile clears both direct-user and
user-group assignments that referenced it.

## Recommendations

- Give most people `viewer` or `helpdesk`; reserve `operator` for staff who
  actively maintain inventory and rules.
- Keep the number of `admin` accounts small — that role can manage users,
  credentials, plugins, and remote access.
- Use a custom role profile when a team needs an unusual mix of permissions
  (for example, view-everything plus run sweeps but no editing).
