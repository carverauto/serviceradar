# __DASHBOARD_TITLE__

Frame-driven table dashboard. Renders rows from the `rows` data frame with
search, status filter, and pagination — a common starting point for
inventory-style dashboards.

```bash
npm install
npm run dev
```

Two fixtures ship with the template — toggle between them in the dev harness
side panel:

- `all-up` — eight devices, all healthy.
- `with-failures` — three devices including one Down.

See [`developer.serviceradar.cloud/docs/v2/dashboard-sdk`](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk)
for the full SDK reference.
