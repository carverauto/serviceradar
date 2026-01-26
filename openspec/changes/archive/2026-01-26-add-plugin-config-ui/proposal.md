# Change: Add dynamic plugin configuration UI

## Why
Plugin packages need a first-class, UI-driven configuration experience so operators can create many plugin checks without hand-editing YAML, while keeping the LiveView surface safe and consistent.

## What Changes
- Accept and persist a plugin `config_schema` (JSON Schema) with each plugin package version.
- Render plugin configuration forms dynamically from the schema in web-ng.
- Validate configuration values against the schema on save and surface errors in the UI.
- Support a documented subset of JSON Schema keywords for stable, predictable UI generation.
- Render custom result views for plugin checks on the Services page using a plugin-defined display contract.
- Version the plugin UI schema/display contract to allow future evolution.

## Impact
- Affected specs: plugin-configuration-ui (new), plugin-results-ui (new), build-web-ui
- Affected code: web-ng LiveViews/components for plugin packages and assignments; plugin package ingestion/storage.
