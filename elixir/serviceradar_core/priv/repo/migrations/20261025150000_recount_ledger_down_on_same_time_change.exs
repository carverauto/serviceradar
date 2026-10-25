defmodule ServiceRadar.Repo.Migrations.RecountLedgerDownOnSameTimeChange do
  @moduledoc """
  Keeps `device_agent_availability.consecutive_down` consistent with `is_available` when a
  ledger row's result changes without `checked_at` advancing
  (`add-merged-device-availability`, design "Tier 1a: the per-agent ledger").

  Migration `20261019180000_add_merged_availability_capture` counts an observation only
  when `checked_at` advances, so that a replayed result with the same `checked_at` is not
  a second failure. The sweep upsert also accepts a different result with an equal
  `checked_at`, and `checked_at` has one-second resolution, so two results for one agent
  in the same second can move a row from available to unavailable while the counter
  stays 0. An unavailable row with no counter is wrong hysteresis evidence and keeps
  `ServiceRadar.Inventory.Availability.CaptureBackfillWorker.pending?/0` true, which
  holds the automatic cutover forever.

  The trigger now also recounts when `is_available` changes. A replay of the same result
  at the same `checked_at` still keeps the stored counter, so nothing is double counted.

  Existing unavailable rows with no counter are seeded with the capture backfill's rule:
  the device's `metadata.sweep_consecutive_failures`, at least 1 and capped at 2. The
  update sets only `consecutive_down`, so `is_available`, `checked_at` and `updated_at`
  keep their values, and it skips a row a writer holds instead of waiting on it.

  serviceradar:allow-startup-maintenance - the repair UPDATE touches only unavailable
  ledger rows whose counter is 0. After the stage-a backfill has run, those are the few
  rows a same-second change produced. It reads the ledger once, never waits on a row
  lock (`SKIP LOCKED`), and rewrites no other column.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    replace_counter_function("NEW.checked_at > OLD.checked_at
             OR NEW.is_available IS DISTINCT FROM OLD.is_available")

    execute("""
    WITH page AS (
      SELECT id FROM #{@prefix}.device_agent_availability
      WHERE is_available = false AND consecutive_down = 0
      FOR NO KEY UPDATE SKIP LOCKED
    )
    UPDATE #{@prefix}.device_agent_availability AS a
    SET consecutive_down = LEAST(GREATEST(COALESCE(
          CASE WHEN d.metadata ->> 'sweep_consecutive_failures' ~ '^[0-9]{1,9}$'
               THEN (d.metadata ->> 'sweep_consecutive_failures')::integer
          END, 1), 1), 2)
    FROM page, #{@prefix}.ocsf_devices AS d
    WHERE a.id = page.id AND d.uid = a.device_uid
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    replace_counter_function("NEW.checked_at > OLD.checked_at")
  end

  defp replace_counter_function(new_observation) do
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_device_agent_availability_consecutive_down()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        NEW.consecutive_down := CASE WHEN NEW.is_available THEN 0 ELSE 1 END;
      ELSIF #{new_observation} THEN
        NEW.consecutive_down := CASE
          WHEN NEW.is_available THEN 0
          WHEN OLD.is_available THEN 1
          ELSE LEAST(OLD.consecutive_down + 1, 2)
        END;
      END IF;

      RETURN NEW;
    END;
    $$
    """)
  end
end
