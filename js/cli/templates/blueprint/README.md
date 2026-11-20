# __DASHBOARD_TITLE__

Palantir Blueprint v6 dashboard package built on `@carverauto/serviceradar-dashboard-sdk/blueprint`
with automatic `.bp6-dark` theme sync, scoped Blueprint styles (no `normalize.css`),
modular SVG icons, and mount-root portal containment.

## Develop

```bash
npm install
npm run dev
```

Two synthetic fixtures ship with the template (`all-up` and `with-failures`) and
can be switched from the dev harness side panel.

## Validate & Build

```bash
npm run validate
npm run build
```

`npm run build` inlines `src/styles.css` directly into `dist/renderer.js` with
zero sidecar `.css` or font assets.
