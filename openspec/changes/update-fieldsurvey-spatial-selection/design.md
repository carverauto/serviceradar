## Context
FieldSurvey uploads can produce partial sessions while users test iOS capture, artifact retry, or Sidekick connectivity. The current review page picks the first recent session after filtering, so an incomplete upload can hide the useful survey. Separately, dashboard playlist SRQL is configured in settings, but review workflows need lightweight ad hoc selection without mutating dashboard configuration.

## Goals
- Let operators quickly choose among recent FieldSurvey sessions.
- Let each user favorite useful surveys and choose a default review/spatial view.
- Let users test SRQL selection against FieldSurvey raster/session entities from the review page.
- Avoid selecting incomplete sessions when a complete floorplan/raster-backed session exists.

## Non-Goals
- Replace dashboard playlist settings.
- Add tenant or customer routing.
- Store large LiDAR/point-cloud artifacts in Postgres.

## Decisions
- Store favorites/defaults as per-user preferences keyed by `session_id`; survey metadata remains shared session attribution.
- Keep dashboard playlist configuration separate from review defaults. Review defaults affect `/spatial` and `/spatial/field-surveys`; dashboard rotation remains driven by dashboard playlist entries.
- Reuse SRQL FieldSurvey entities for preview/select. The review page accepts raster candidates and session candidates but still loads review details through existing FieldSurvey review APIs.
