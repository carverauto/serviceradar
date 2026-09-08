# Design Notes

## Summary Source of Truth
- Use the latest status per **service identity** to compute summary counts.
- Service identity should be defined explicitly (e.g., `agent_id + service_name + service_type + partition`).
- Optionally show a "Last updated" timestamp for operator confidence.

## Widget Replacement
Replace the existing "Service Type" card with a status distribution by check.

## Live Updates
- Use PubSub-driven refresh for `/services` so summary counts and lists update without manual reload.
- Debounce refresh to avoid excessive SRQL queries.
