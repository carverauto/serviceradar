# __DASHBOARD_TITLE__

Map dashboard built on `useDeckMap` + `useDeckLayers` + `useScreenLod`. The
reference dashboard for the ServiceRadar map pattern.

```bash
npm install
npm run dev
```

Three fixtures swap from the dev harness side panel:

- `all-regions` — ten sites across AMERICAS / EMEA / APAC
- `americas-only` — four sites in AMERICAS
- `dense-synthetic` — about 1,400 invented sites, enough to see the map switch
  between grouped markers (zoomed out) and individual sites (zoom 5 and in)

## Level of detail

`useScreenLod` turns the filtered sites into one marker per screen cell while
the map is zoomed out, and hands back the sites themselves from `enterZoom`
up. The band only flips back to groups at `exitZoom`, so zooming through the
gap does not flicker. Groups are fixed in world space, so panning does not
reshuffle them or rebuild the layer. Clicking a group flies to its centre at
`enterZoom`. Tune `LOD` in `src/main.jsx`.

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
- `useScreenLod` (grouped markers when zoomed out)
- `useMapPopup` (React-rendered Mapbox popup)

See [`developer.serviceradar.cloud/docs/v2/dashboard-sdk`](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk)
for the full reference.
