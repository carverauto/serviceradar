## 1. Data Model + Sync
- [ ] 1.1 Add `jdm_definition` (or final name) to ZenRule and ZenRuleTemplate resources with Ash codegen + migrate.
- [ ] 1.2 Backfill JDM definitions for existing rules/templates using the current template compiler.
- [ ] 1.3 Update Zen rule sync to KV to prefer JDM definition and validate JSON before sync.

## 2. React Editor Integration
- [ ] 2.1 Add `phoenix_react_server` dependency/config and supervision entry.
- [ ] 2.2 Add `@gorules/jdm-editor` assets (CSS + JS) and bundle with app assets.
- [ ] 2.3 Create React wrapper component that exposes canvas + JSON toggle and emits JDM changes.
- [ ] 2.4 Create Phoenix React component helper and mount in LiveView with tenant-scoped props.

## 3. Zen Rule Editor UX
- [ ] 3.1 Replace preset modals with a single Zen rule editor layout (list/library + editor).
- [ ] 3.2 Add create/edit/clone flows for rules and library items.
- [ ] 3.3 Gate edit actions by RBAC (operator/admin) and provide read-only view for viewers.

## 4. Tests + Docs
- [ ] 4.1 Add LiveView tests for rule edit/save and library clone flows.
- [ ] 4.2 Add core tests for JDM validation + sync behavior.
- [ ] 4.3 Update docs with rule authoring guidance and JSON examples.
