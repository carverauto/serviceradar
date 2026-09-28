# __DASHBOARD_TITLE__

A minimum-viable ServiceRadar dashboard package. Renders the rows of a single
`primary` data frame.

## Develop

```bash
npm install
npm run dev
```

The dev server runs the SDK harness with HMR. Edits to `src/main.jsx` remount
the renderer in place; the Mapbox token, theme, and active fixture are
controllable from the side panel.

## Validate

```bash
npm run validate
```

Static check — no build, no network. Validates `dashboard.config.mjs`, the
synthesized manifest, the sample frames against declared `data_frames`, and the
sample settings against any declared `settings_schema`.

## Build

```bash
npm run build
```

Writes `dist/renderer.js`, `dist/manifest.json` (with the renderer SHA256
digest stamped in), `dist/sample-frames.json`, and `dist/sample-settings.json`.
The build runs `validate` first and refuses to write `dist/` on validation
failure.

## Publish

When ready to deploy to a real ServiceRadar instance:

```bash
serviceradar-dashboard publish --instance https://serviceradar.example.com --route my-dashboard
```

The bearer token comes from `SERVICERADAR_TOKEN` env or `--token`. The CLI
verifies the manifest digest matches the renderer artifact before uploading.

## Documentation

- [Dashboard SDK reference](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk)
- Reference dashboard: `~/src/example-dashboard`
