# Change: Refactor FieldSurvey iOS Capture and Review

## Why
The current FieldSurvey iOS app mixes LiDAR capture, Sidekick RF ingestion, native iPhone Wi-Fi/BLE experiments, AR object overlays, 3D RF billboards, offline export, and backend streaming in one heavy capture view. That makes the app laggy and hard to validate in the field.

FieldSurvey needs a smaller product loop: walk a room with LiDAR active, collect RF only from Sidekick, persist or stream the raw observations and pose samples, then review the survey as a 2D room/heatmap view.

## What Changes
- Reframe the iOS app around a capture-first workflow: configure Sidekick, start survey, walk room, stop, save/upload, review.
- Remove native iPhone Wi-Fi and BLE RF survey inputs from the capture path; Sidekick is the only Wi-Fi/RF survey source.
- Remove 3D RF/AP visualization from the LiDAR capture view so RoomPlan/ARKit performance takes priority.
- Add a lightweight 2D in-app survey review that projects room geometry and RF heatmap samples onto a top-down floor-plane.
- Keep ServiceRadar/web-ng as the polished historical survey viewer using the backend fused RF/pose tables.
- Preserve offline operation: local saved sessions must remain reviewable and uploadable later.

## Impact
- Affected specs: field-survey-ios-app, field-survey-sidekick
- Affected code:
  - `swift/FieldSurvey/FieldSurvey/Views/**` for capture flow, 2D review, and simplified navigation.
  - `swift/FieldSurvey/FieldSurvey/Network/**` for Sidekick-only RF ingestion and upload/offline data flow.
  - `swift/FieldSurvey/FieldSurvey/Managers/**` for session persistence and RoomPlan/pose capture boundaries.
  - `elixir/web-ng/**` for the eventual ServiceRadar saved-survey heatmap view.
  - `openspec/changes/add-fieldsurvey-sidekick-bridge/**` remains the Sidekick transport/data contract work; this change owns the iOS product shape.
