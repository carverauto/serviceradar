---
title: Roles & Permissions
---

# Roles & Permissions

ServiceRadar uses role-based access control (RBAC) to decide what each signed-in
user can see and do. Every user is assigned a **role**, and every role grants a
set of **permissions** drawn from a fixed permission catalog. Administrators can
also create **custom role profiles** that grant a tailored subset of permissions.

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

The role each user holds is the primary access decision. Permissions below are
the building blocks that define exactly what each role grants.

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

## Custom role profiles

When the built-in roles do not match a team's needs, an administrator can create
a **custom role profile**: a named bundle of specific permission keys. A user
assigned a custom profile receives exactly the permissions the profile lists,
instead of the defaults of a built-in role. Built-in Viewer/Operator/Admin
still get personal API credentials (`settings.api_credentials.manage`) and MCP
(`settings.mcp.manage`) because those default to every role; omit them on a
custom profile (the `demo` profile should) to hide **Settings -> API
Credentials**, **MCP Sessions**, and to refuse `/mcp` and MCP OAuth consent.
Omit `plugins.view` on the same profile to hide **Dashboard Packages** and the
Edge Ops add-on catalog.

The four built-in roles also exist as system role profiles (`Admin`,
`Operator`, `Helpdesk`, `Viewer`). System profiles cannot be edited or deleted;
custom profiles can.

### Managing role profiles in the UI

Role profiles are managed under **Settings → Auth/Users**:

- **Settings → Auth → RBAC** — browse the permission catalog and create, edit,
  or delete custom role profiles. Each profile is given a name, an optional
  description, and a checklist of permissions.
- **Settings → Auth → Users** — view users and assign each user a role or a
  custom role profile.

Managing role profiles requires the **Manage RBAC policies**
(`settings.rbac.manage`) permission; managing users requires **Manage users and
auth** (`settings.auth.manage`). Both default to `admin`.

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

A user can hold **both**: a built-in role (the rung) and a role profile (a
named extra permission set). Mapping an IdP group onto a profile does **not**
require putting that profile in the default-role dropdown. That dropdown is
only the four built-in rungs. See
[Group Permission Mapping](./group-permission-mapping.md).

## How roles are assigned to users

Each user record carries a built-in role and, optionally, a role profile.
Assign or change those from **Settings → Auth → Users**, or let SSO apply them
from **Settings → Authorization** mappings on each sign-in.

When a user's role or profile changes — or a profile's permission list is
edited — ServiceRadar invalidates the affected RBAC caches so the new
permissions take effect on the user's next request. Removing or deleting a
profile clears the assignments that referenced it.

## Recommendations

- Give most people `viewer` or `helpdesk`; reserve `operator` for staff who
  actively maintain inventory and rules.
- Keep the number of `admin` accounts small — that role can manage users,
  credentials, plugins, and remote access.
- Use a custom role profile when a team needs an unusual mix of permissions
  (for example, view-everything plus run sweeps but no editing).
