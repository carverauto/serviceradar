defmodule ServiceRadar.Repo.Migrations.AddMergedAvailabilityCutover do
  @moduledoc """
  Stage c (cutover) of `add-merged-device-availability`. Catalog changes and trigger
  bodies only; the one bulk step is enqueued, not run.

  * `availability_settings.transition_events`: the deployment setting that gates the
    resolver's `device.available` / `device.unavailable` events (design Decision 8, Open
    Question 6). It starts on exactly when some sweep group already emits availability
    events, so cutting over keeps the deployment's opt-in as it was.
  * The compatibility-table trigger copies a new device's initial `is_available` in
    every mode, so a device created after cutover has a legacy value; updates are still
    copied only in `legacy` and `shadow`, where the legacy writers own the column.
  * The inventory rollups count by `availability_state` (`available`, `unavailable`,
    and a new `unknown` key) instead of `COALESCE(is_available, false)`, so the counts,
    the device order and the badge read the same value. The statement-level triggers
    of `20261019150000` keep their shape; a `WHEN` clause cannot narrow them, because a
    trigger with transition tables cannot name columns, and they already count only
    the statement's changed rows. The counters are rebuilt once after the migration by
    `ServiceRadar.Inventory.Availability.CutoverWorker` (phase `"refresh_rollups"`),
    enqueued here, because the stored counters were computed by the old rule.

  serviceradar:allow-startup-maintenance - the INSERT, UPDATE and DELETE statements in
  `up` are trigger and function bodies that run later, the settings UPDATE writes the
  single settings row, and the job INSERT enqueues the one rollup rebuild; nothing is
  backfilled here. The DELETE in `down` removes only this migration's pending job.
  """

  use Ecto.Migration

  @prefix "platform"
  @worker "ServiceRadar.Inventory.Availability.CutoverWorker"
  @now_utc "(now() AT TIME ZONE 'utc')"
  @active "deleted_at IS NULL AND source_retired_at IS NULL"

  @events [
    {"insert", [{"inventory_new", 1}]},
    {"update", [{"inventory_old", -1}, {"inventory_new", 1}]},
    {"delete", [{"inventory_old", -1}]}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.availability_settings
      ADD COLUMN transition_events boolean NOT NULL DEFAULT false
    """)

    execute("""
    UPDATE #{@prefix}.availability_settings
    SET transition_events = EXISTS (
      SELECT 1 FROM #{@prefix}.sweep_groups WHERE emit_availability_events
    )
    WHERE singleton
    """)

    execute(legacy_trigger_sql(:insert_in_every_mode))

    for {event, sources} <- @events, do: execute(rollup_trigger_sql(event, sources, :state))
    execute(refresh_sql(:state))

    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    VALUES ('available', 'maintenance', '#{@worker}',
            '{"phase": "refresh_rollups"}'::jsonb, 20)
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@worker}' AND args ->> 'phase' = 'refresh_rollups'
      AND state IN ('available', 'scheduled', 'retryable')
    """)

    for {event, sources} <- @events, do: execute(rollup_trigger_sql(event, sources, :boolean))
    execute(refresh_sql(:boolean))
    execute(legacy_trigger_sql(:legacy_modes_only))

    execute(
      "ALTER TABLE #{@prefix}.availability_settings DROP COLUMN IF EXISTS transition_events"
    )
  end

  # The compatibility-table trigger function of `20261019180000`. `:legacy_modes_only`
  # is that migration's body.
  defp legacy_trigger_sql(scope) do
    condition =
      case scope do
        :insert_in_every_mode ->
          "TG_OP = 'INSERT' OR #{@prefix}.availability_mode() IN ('legacy', 'shadow')"

        :legacy_modes_only ->
          "#{@prefix}.availability_mode() IN ('legacy', 'shadow')"
      end

    """
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_availability_legacy()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN
        INSERT INTO #{@prefix}.device_availability_legacy AS legacy
          (device_uid, is_available, updated_at)
        VALUES (NEW.uid, NEW.is_available, #{@now_utc})
        ON CONFLICT (device_uid) DO UPDATE
          SET is_available = EXCLUDED.is_available,
              updated_at = EXCLUDED.updated_at
          WHERE legacy.is_available IS DISTINCT FROM EXCLUDED.is_available;
      END IF;

      RETURN NULL;
    END;
    $$
    """
  end

  # The counter key a device row counts under: its canonical state (`:state`), or the
  # boolean of `20261019150000` (`:boolean`), whose key set has no `unknown`.
  defp counter_key(:state, row),
    do:
      "CASE #{row}availability_state WHEN 'available' THEN 'available' " <>
        "WHEN 'unavailable' THEN 'unavailable' ELSE 'unknown' END"

  defp counter_key(:boolean, row),
    do: "CASE WHEN COALESCE(#{row}is_available, false) THEN 'available' ELSE 'unavailable' END"

  @serialize_sql """
  IF NOT serialized THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0));
    serialized := true;
  END IF;
  """

  # The statement-level rollup functions of `20261019150000`, with the availability
  # counter key as a parameter.
  defp rollup_trigger_sql(event, sources, rule) do
    changes =
      Enum.map_join(sources, "\nUNION ALL\n", fn {relation, sign} ->
        """
        SELECT #{sign}::bigint AS delta, #{counter_key(rule, "")} AS availability_key,
               COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type_key,
               COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_key
        FROM #{relation}
        WHERE #{@active}
        """
      end)

    """
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_inventory_rollup_#{event}()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      change record;
      serialized boolean := false;
    BEGIN
      IF current_setting('platform.skip_inventory_rollup', true) = 'on' THEN
        RETURN NULL;
      END IF;

      -- Only the statement's changed rows are read. An upsert fires its UPDATE and
      -- INSERT triggers separately, so sorting keys within one trigger cannot order
      -- locks across them. Every trigger takes one transaction lock before its first
      -- counter write; a statement with no net change takes none.
      FOR change IN
        WITH changes AS (#{changes})
        SELECT key, SUM(delta)::bigint AS delta
        FROM changes
        CROSS JOIN LATERAL (VALUES ('total'), (availability_key)) AS counters(key)
        GROUP BY key HAVING SUM(delta) <> 0 ORDER BY key
      LOOP
        #{@serialize_sql}
        INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
        VALUES (change.key, change.delta, now())
        ON CONFLICT (key) DO UPDATE
          SET value = #{@prefix}.device_inventory_counts.value + EXCLUDED.value,
              updated_at = now();
      END LOOP;

      #{dimension_sql(changes, "type", "type_key", "type")}
      #{dimension_sql(changes, "vendor", "vendor_key", "vendor_name")}
      RETURN NULL;
    END;
    $$;
    """
  end

  defp dimension_sql(changes, dimension, projected_key, column) do
    """
    FOR change IN
      WITH changes AS (#{changes})
      SELECT #{projected_key} AS key, SUM(delta)::bigint AS delta
      FROM changes
      GROUP BY #{projected_key} HAVING SUM(delta) <> 0 ORDER BY #{projected_key}
    LOOP
      #{@serialize_sql}
      INSERT INTO #{@prefix}.device_inventory_#{dimension}_counts (#{column}, count, updated_at)
      VALUES (change.key, change.delta, now())
      ON CONFLICT (#{column}) DO UPDATE
        SET count = #{@prefix}.device_inventory_#{dimension}_counts.count + EXCLUDED.count,
            updated_at = now();

      IF change.delta < 0 THEN
        DELETE FROM #{@prefix}.device_inventory_#{dimension}_counts
        WHERE #{column} = change.key AND count <= 0;
      END IF;
    END LOOP;
    """
  end

  # `refresh_device_inventory_rollups()` of `20261005120000`, counting availability by
  # the given rule. The `unknown` key is written only by the state rule.
  defp refresh_sql(rule) do
    availability_keys =
      case rule do
        :state -> ["available", "unavailable", "unknown"]
        :boolean -> ["available", "unavailable"]
      end

    availability_counts =
      Enum.map_join(availability_keys, "\n", fn key ->
        """
        INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
        SELECT '#{key}', COUNT(*)::bigint, now()
        FROM #{@prefix}.ocsf_devices
        WHERE #{@active} AND #{counter_key(rule, "")} = '#{key}';
        """
      end)

    """
    CREATE OR REPLACE FUNCTION #{@prefix}.refresh_device_inventory_rollups()
    RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      TRUNCATE TABLE #{@prefix}.device_inventory_counts;
      TRUNCATE TABLE #{@prefix}.device_inventory_type_counts;
      TRUNCATE TABLE #{@prefix}.device_inventory_vendor_counts;

      INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
      SELECT 'total', COUNT(*)::bigint, now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{@active};

      #{availability_counts}

      INSERT INTO #{@prefix}.device_inventory_type_counts (type, count, updated_at)
      SELECT COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type,
             COUNT(*)::bigint AS count,
             now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{@active}
      GROUP BY COALESCE(NULLIF(trim(type), ''), 'Unknown');

      INSERT INTO #{@prefix}.device_inventory_vendor_counts (vendor_name, count, updated_at)
      SELECT COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_name,
             COUNT(*)::bigint AS count,
             now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{@active}
      GROUP BY COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown');
    END;
    $$;
    """
  end
end
