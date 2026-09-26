-- One row per Trivy report event, as CNPG keeps.
-- A Trivy report's event keeps its id across rescans while its time moves to
-- the latest observation, and CNPG replaces it by id. This table keys events
-- on (id, time), so until EventWriter deleted the id before loading, every
-- rescan added a row here. Keep each id's latest row and drop the rest.
-- Safe to repeat: a second run finds no older rows. Measured on StarRocks
-- 3.5.21: rows of other providers, duplicated or not, are untouched.
DELETE FROM serviceradar.events
USING (
  SELECT id, max(time) AS latest
  FROM serviceradar.events
  WHERE log_provider = 'trivy'
  GROUP BY id
) AS latest_report
WHERE events.id = latest_report.id
  AND events.time < latest_report.latest
  AND events.log_provider = 'trivy';
