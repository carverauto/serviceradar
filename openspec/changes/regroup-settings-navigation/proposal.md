# Change: Regroup Settings navigation by what each page controls

## Why

An audit of the Settings catalog found pages filed under groups that do not
match what they control. The three remote-access pages were split across two
categories. The shared credential vault sat under Discovery. Threat and
vulnerability feeds sat under Network Services, and a one-knob retention page
sat under Fleet Health. Operators browsing the tree look in the wrong place.
The product owner approved the regrouping.

## What Changes

Only catalog placement and grouping change. Routes, permissions and LiveViews
stay the same, so no URL changes and no redirects.

- System → Security gains three subgroups next to *Users & Access*:
  *Credentials* (API Credentials, MCP Sessions, and Credentials and Rules),
  *Remote Access* (Session Recordings, Host Keys, Desktop Targets), and
  *Threat Intelligence* (Threat Intel, Vulnerability Feeds).
- Composite Checks sits next to Availability Sources in Network Services →
  Discovery.
- Telemetry Onboarding moves to Edge Ops → Sites & Collectors. Endpoint
  Inventory and Mail move to System → Platform beside Data retention.
- A new System → Dashboards group holds Dashboard Packages and the FieldSurvey
  dashboard playlist.
- Profile moves out of *Users & Access* into a new System → Personal group. It
  stays hidden from the tree and opens from the account menu.
- The System "Cluster" group is renamed "Platform" (display title only; the
  group id, routes and permissions stay). The Cluster Status page keeps its name.
- Moved pages keep the status cards they showed before the move.
- A catalog test requires each subgroup to render as one section of its group,
  and a shell test requires each moved page to keep its status cards.

## Impact

- Affected specs: build-web-ui
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/settings/catalog.ex`
  and `status_cards.ex`, plus their tests.
- Docs: `docs/docs/web-ui-overview.md`, plus navigation paths in page guides.
