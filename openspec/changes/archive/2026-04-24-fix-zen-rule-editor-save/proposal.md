# Change: Fix Zen rule editor save flow for JDM rules

## Why
The Zen rule editor crashes during edit flows because the LiveView lacks `handle_params/3`, preventing rule updates from being saved and synced to KV.

## What Changes
- Ensure the Zen rule editor loads rule data on route param changes without crashing.
- Persist JDM definition changes (including rule metadata edits) reliably on save.
- Keep the KV sync path intact after successful updates.

## Impact
- Affected specs: zen-rule-editor
- Affected code: web-ng LiveView for the Zen rule editor, rule update pipeline
