# __DASHBOARD_TITLE__

Map dashboard built on `useDeckMap` + `useDeckLayers`. The reference
dashboard for the ServiceRadar map pattern.

```bash
npm install
npm run dev
```

Two fixtures swap from the dev harness side panel:

- `all-regions` — ten sites across AMERICAS / EMEA / APAC
- `americas-only` — four sites in AMERICAS

## Mapbox token

The renderer falls back to a token-free background when no Mapbox token is
configured. To render the real Mapbox basemap, set `MAPBOX_TOKEN` in your
environment, paste the token into the dev harness side panel, or update
`fixtures/sample-settings.json#mapbox.access_token`.

## Hooks used

- `useFrameRows` (with `SITE_SHAPE` projection)
- `useFilterState` (debounced search)
- `useIndexedRows` (Set-intersection region filter)
- `useDeckMap` + `useDeckLayers` (memoized scatter layer)
- `useMapPopup` (React-rendered Mapbox popup)

See [`developer.serviceradar.cloud/docs/v2/dashboard-sdk`](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk)
for the full reference.
