# Change: Zen Rule Editor with JDM Canvas + JSON View

## Why
Operators cannot inspect or edit the actual Zen rule JSON today; they are forced into a presets-within-presets UI that hides rule composition and blocks new rule types. We need a real rule editor so tenants can author, edit, and understand Zen rules without copying raw JSON into KV by hand.

## What Changes
- Replace the current preset modal UX with a first-class Zen rule editor that exposes the actual JSON Decision Model (JDM) for each rule.
- Embed the GoRules JDM editor (React) in web-ng using `phoenix_react_server`, with a toggle between canvas and JSON views and round-trip sync.
- Store each Zen rule’s JDM definition in CNPG and sync it to KV (no manual KV edits); enable creating new rules and new rule types from scratch.
- Provide a rule library (tenant-scoped) for reusable rule types, with cloning into rules and direct editing of rule definitions.
- Enforce existing auth/RBAC and tenant scoping; only operator/admin roles can create/edit/delete.
- Migrate existing Zen rules/templates to the new stored JDM definition without losing behavior.

## Impact
- Affected specs: new `zen-rule-editor` capability; updates to existing rule builder change set.
- Affected code: web-ng (LiveView + React mount), core-elx (Ash resources + rule sync), assets bundling, docs for rule authoring.
