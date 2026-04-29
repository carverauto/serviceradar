---
name: fieldsurvey-local-web-ng
description: Run ServiceRadar web-ng locally against the Kubernetes demo namespace FieldSurvey data, including CNPG NodePort access, NATS Object Store artifact access, authenticated browser checks, and Playwright screenshots for dashboard and FieldSurvey review iteration.
---

# FieldSurvey Local Web-NG

Use this skill when iterating on `elixir/web-ng` FieldSurvey dashboard, spatial review, heatmap, raster, floorplan, or artifact rendering and you need fast local feedback against real `demo` data.

## Workflow

1. Start local web-ng from the repo root:

   ```bash
   .agents/skills/fieldsurvey-local-web-ng/scripts/start-local-web-ng.sh
   ```

   The script:
   - reads current `demo` CNPG credentials from `serviceradar-db-credentials`;
   - discovers a reachable Kubernetes node for `cnpg-local-dev` NodePort;
   - extracts demo NATS creds/certs into `tmp/fieldsurvey-local/`;
   - starts a local NATS port-forward for Object Store artifact reads;
   - runs `mix phx.server` in `elixir/web-ng` with `SERVICERADAR_LOCAL_LOG_LEVEL=info`.

2. Open and log in with Playwright:

   ```bash
   playwright-cli open http://localhost:4000/dashboard
   playwright-cli fill <email-ref> root@localhost
   playwright-cli fill <password-ref> 'serviceradar2026!'
   playwright-cli click <sign-in-ref>
   ```

   If Chromium is missing, run:

   ```bash
   playwright-cli install-browser chromium
   ```

3. Capture the dashboard and review pages:

   ```bash
   playwright-cli resize 2048 1400
   playwright-cli screenshot --filename=.playwright-cli/fieldsurvey-dashboard-local.png
   playwright-cli goto http://localhost:4000/spatial/field-surveys
   playwright-cli screenshot --filename=.playwright-cli/fieldsurvey-review-local.png
   ```

4. Inspect the dashboard FieldSurvey card:

   ```bash
   playwright-cli --raw eval "JSON.stringify(Array.from(document.querySelectorAll('[data-testid=fieldsurvey-heatmap]')).map(el => { const r = el.getBoundingClientRect(); return {width:r.width, height:r.height, style:el.getAttribute('style'), floorplan:el.querySelectorAll('line').length, circles:el.querySelectorAll('circle').length, images:el.querySelectorAll('image').length}; }))"
   ```

5. Run the repeatable smoke check for the dashboard card, settings preview, and FieldSurvey review page:

   ```bash
   .agents/skills/fieldsurvey-local-web-ng/scripts/field-survey-smoke.sh
   ```

   This saves screenshots under `.playwright-cli/` and fails if the dashboard card has no floorplan, the settings SRQL preview cannot resolve a persisted raster, or the review page does not load sessions.

## Notes

- Prefer the CNPG NodePort over `kubectl port-forward` for Postgres. The port-forward is too fragile under web-ng startup connection churn.
- Use the NATS port-forward only for Object Store artifacts; it is lighter and stable enough for floorplan/point-cloud fetches.
- Re-read Kubernetes secrets each run. Demo DB credentials can change after rollouts.
- Keep screenshots under `.playwright-cli/`; do not commit them.
- The local log-level guard prevents debug logs from printing NATS JWT/NKEY material.
