# @serviceradar/create-dashboard

npm-create scaffolder for ServiceRadar dashboards.

```bash
npm create @serviceradar/dashboard@latest my-dashboard
# or with a template:
npm create @serviceradar/dashboard@latest my-dashboard -- --template react-map
```

This package is a thin shim that forwards to `serviceradar-cli dashboard init`.
The canonical command-line surface lives in
[`@serviceradar/cli`](https://www.npmjs.com/package/@serviceradar/cli);
this package exists so the npm-create idiom (`npm create @scope/name`) works
without a separate install step.

For full documentation, see the
[ServiceRadar Dashboard SDK developer portal](https://developer.serviceradar.com/docs/v2/dashboard-sdk).
