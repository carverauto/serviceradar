# Change: Improve FieldSurvey spatial survey selection

## Why
The FieldSurvey review and spatial pages currently default to the newest visible session, which can select incomplete smoke-test uploads instead of the useful floorplan-backed survey. Operators also need a way to browse recent surveys, mark good surveys, and drive selection from SRQL without configuring the dashboard playlist.

## What Changes
- Add recent-survey selection controls to the FieldSurvey review/spatial survey surfaces.
- Add per-user favorite and default view preferences for FieldSurvey survey sessions.
- Add SRQL candidate preview/select controls that reuse FieldSurvey raster/session SRQL entities.
- Prefer explicit URL selections, user defaults, favorites, and complete floorplan/raster-backed sessions before falling back to the newest upload.

## Impact
- Affected specs: `build-web-ui`, `srql`
- Affected code: `elixir/serviceradar_core` spatial preference storage, `elixir/web-ng` FieldSurvey review/spatial LiveViews, FieldSurvey review helpers, tests
