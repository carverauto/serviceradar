defmodule ServiceRadar.Repo.Migrations.BatchDeviceInventoryRollups do
  use Ecto.Migration

  @events [
    {"insert", "NEW TABLE AS inventory_new", [{"inventory_new", 1}]},
    {"update", "OLD TABLE AS inventory_old NEW TABLE AS inventory_new",
     [{"inventory_old", -1}, {"inventory_new", 1}]},
    {"delete", "OLD TABLE AS inventory_old", [{"inventory_old", -1}]}
  ]

  @serialize_sql """
  IF NOT serialized THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0));
    serialized := true;
  END IF;
  """

  def up do
    execute("DROP TRIGGER trg_ocsf_devices_inventory_rollup ON platform.ocsf_devices")

    for {event, referencing, sources} <- @events do
      execute(function_sql(event, sources))

      execute("""
      CREATE TRIGGER trg_ocsf_devices_inventory_rollup_#{event}
      AFTER #{String.upcase(event)} ON platform.ocsf_devices
      REFERENCING #{referencing}
      FOR EACH STATEMENT
      EXECUTE FUNCTION platform.trg_ocsf_devices_inventory_rollup_#{event}()
      """)
    end
  end

  def down do
    for {event, _, _} <- @events do
      execute("DROP TRIGGER trg_ocsf_devices_inventory_rollup_#{event} ON platform.ocsf_devices")
      execute("DROP FUNCTION platform.trg_ocsf_devices_inventory_rollup_#{event}()")
    end

    # Keep the previous function and its helper intact for a transactional rollback.
    execute("""
    CREATE TRIGGER trg_ocsf_devices_inventory_rollup
    AFTER INSERT OR UPDATE OR DELETE ON platform.ocsf_devices
    FOR EACH ROW EXECUTE FUNCTION platform.trg_ocsf_devices_inventory_rollup()
    """)
  end

  defp function_sql(event, sources) do
    changes =
      Enum.map_join(sources, "\nUNION ALL\n", fn {relation, sign} ->
        """
        SELECT #{sign}::bigint AS delta, COALESCE(is_available, false) AS available,
               COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type_key,
               COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_key
        FROM #{relation}
        WHERE deleted_at IS NULL AND source_retired_at IS NULL
        """
      end)

    """
    CREATE FUNCTION platform.trg_ocsf_devices_inventory_rollup_#{event}()
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
        CROSS JOIN LATERAL (
          VALUES ('total'), (CASE WHEN available THEN 'available' ELSE 'unavailable' END)
        ) AS counters(key)
        GROUP BY key HAVING SUM(delta) <> 0 ORDER BY key
      LOOP
        #{@serialize_sql}
        INSERT INTO platform.device_inventory_counts (key, value, updated_at)
        VALUES (change.key, change.delta, now())
        ON CONFLICT (key) DO UPDATE
          SET value = platform.device_inventory_counts.value + EXCLUDED.value,
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
      INSERT INTO platform.device_inventory_#{dimension}_counts (#{column}, count, updated_at)
      VALUES (change.key, change.delta, now())
      ON CONFLICT (#{column}) DO UPDATE
        SET count = platform.device_inventory_#{dimension}_counts.count + EXCLUDED.count,
            updated_at = now();

      IF change.delta < 0 THEN
        DELETE FROM platform.device_inventory_#{dimension}_counts
        WHERE #{column} = change.key AND count <= 0;
      END IF;
    END LOOP;
    """
  end
end
