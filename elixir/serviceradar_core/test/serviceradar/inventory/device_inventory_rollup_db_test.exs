defmodule ServiceRadar.Inventory.DeviceInventoryRollupDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Migration.Runner
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.BatchDeviceInventoryRollups, as: Migration

  @moduletag :integration
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261019150000_batch_device_inventory_rollups.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  @wait_ms 15_000

  setup :observe_rollup_writes

  # Sessions on their own connections must not queue behind the sandbox owner's refresh.
  defp observe_rollup_writes(%{separate_sessions: true}), do: :ok

  defp observe_rollup_writes(_context) do
    Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
    Repo.query!("CREATE TEMP TABLE rollup_writes (relation text, operation text, key text)")

    Repo.query!("""
    CREATE FUNCTION pg_temp.record_rollup_write() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO rollup_writes VALUES (
        TG_TABLE_NAME, TG_OP,
        CASE WHEN TG_LEVEL = 'ROW' THEN
          COALESCE(to_jsonb(NEW), to_jsonb(OLD)) ->> TG_ARGV[0]
        END
      );
      RETURN NULL;
    END;
    $$
    """)

    for {table, key} <- [
          {"device_inventory_counts", "key"},
          {"device_inventory_type_counts", "type"},
          {"device_inventory_vendor_counts", "vendor_name"}
        ] do
      Repo.query!("""
      CREATE TRIGGER record_rollup_row AFTER INSERT OR UPDATE ON platform.#{table}
      FOR EACH ROW EXECUTE FUNCTION pg_temp.record_rollup_write('#{key}')
      """)

      # Also observe cleanup statements that delete zero rows.
      Repo.query!("""
      CREATE TRIGGER record_rollup_cleanup AFTER DELETE ON platform.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.record_rollup_write()
      """)
    end

    %{prefix: prefix()}
  end

  test "availability batches write each changed status counter once", %{prefix: prefix} do
    for size <- [1, 500] do
      batch = "#{prefix}#{size}-"
      insert_batch(batch, size)
      clear_writes()

      Repo.query!(
        "UPDATE platform.ocsf_devices SET is_available = false, availability_state = 'unavailable' WHERE starts_with(uid, $1)",
        [batch]
      )

      assert writes() == [
               ["device_inventory_counts", "UPDATE", "available"],
               ["device_inventory_counts", "UPDATE", "unavailable"]
             ]

      assert_counts()
      clear_writes()

      Repo.query!(
        "UPDATE platform.ocsf_devices SET is_available = false, availability_state = 'unavailable', hostname = 'host01.example.com' WHERE starts_with(uid, $1)",
        [batch]
      )

      assert writes() == []
      assert_counts()
    end
  end

  test "opposing changes in one statement cancel without counter writes", %{prefix: prefix} do
    insert_batch(prefix, 20)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET is_available = false, availability_state = 'unavailable' WHERE uid = ANY($1)",
      [Enum.map(1..10, &"#{prefix}#{&1}")]
    )

    clear_writes()

    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET is_available = NOT is_available,
          availability_state = CASE WHEN is_available THEN 'unavailable' ELSE 'available' END
      WHERE starts_with(uid, $1)
      """,
      [prefix]
    )

    assert writes() == []
    assert_counts()
  end

  test "insert, upsert, reclassification, retirement and deletion match a fresh count", %{
    prefix: prefix
  } do
    insert_batch(prefix, 4)
    assert_counts()

    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices (uid, is_available, type, vendor_name)
      VALUES ($1, false, 'router', 'Example Networks'), ($2, NULL, '', NULL)
      ON CONFLICT (uid) DO UPDATE SET is_available = EXCLUDED.is_available,
        type = EXCLUDED.type, vendor_name = EXCLUDED.vendor_name
      """,
      ["#{prefix}1", "#{prefix}5"]
    )

    assert_counts()
    clear_writes()

    Repo.query!(
      "UPDATE platform.ocsf_devices SET type = 'access_point' WHERE uid = $1",
      ["#{prefix}1"]
    )

    refute Enum.any?(writes(), fn [table, _, _] ->
             table in ["device_inventory_counts", "device_inventory_vendor_counts"]
           end)

    assert_counts()

    for assignment <- [
          "source_retired_at = now()",
          "is_available = true, type = 'switch', vendor_name = 'Example Devices'",
          "source_retired_at = NULL",
          "deleted_at = now()",
          "is_available = NULL, type = NULL, vendor_name = ''",
          "deleted_at = NULL"
        ] do
      Repo.query!("UPDATE platform.ocsf_devices SET #{assignment} WHERE uid = $1", ["#{prefix}1"])
      assert_counts()
    end

    Repo.query!("DELETE FROM platform.ocsf_devices WHERE starts_with(uid, $1)", [prefix])
    assert_counts()

    clear_writes()
    Repo.query!("DELETE FROM platform.ocsf_devices WHERE starts_with(uid, $1)", [prefix])
    assert writes() == []
  end

  test "bulk bypass, refresh and transaction rollback preserve their contracts", %{prefix: prefix} do
    before = counts()
    Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")
    insert_batch(prefix, 12)
    assert counts() == before
    assert writes() == []

    Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'off'")
    Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
    assert_counts()
    refreshed = counts()

    assert {:error, :rollback_probe} =
             Repo.transaction(fn ->
               Repo.query!(
                 "UPDATE platform.ocsf_devices SET is_available = false, type = 'router' WHERE starts_with(uid, $1)",
                 [prefix]
               )

               assert_counts()
               Repo.rollback(:rollback_probe)
             end)

    assert counts() == refreshed
    assert_counts()
  end

  # A rebuild truncates every rollup table and rescans the whole inventory, so a
  # batch the size of one plugin result's device inventory must ride the
  # statement triggers instead of paying for a rebuild inside its commit.
  test "a sync of a few hundred devices keeps the rollups without rebuilding them", %{
    prefix: prefix
  } do
    ServiceRadar.TestSupport.start_core!()

    for table <- [
          "device_inventory_counts",
          "device_inventory_type_counts",
          "device_inventory_vendor_counts"
        ] do
      Repo.query!("""
      CREATE TRIGGER record_rollup_truncate AFTER TRUNCATE ON platform.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.record_rollup_write()
      """)
    end

    updates =
      for n <- 1..250 do
        %{
          "ip" => nil,
          "hostname" => "ap#{n}.example.com",
          "source" => "integration-test",
          "is_available" => rem(n, 4) != 0,
          "metadata" => %{
            "integration_type" => "test-integration",
            "integration_id" => "#{prefix}#{n}",
            "type" => "access_point",
            "vendor_name" => "Example Networks"
          }
        }
      end

    clear_writes()

    assert :ok =
             SyncIngestor.ingest_updates(updates,
               actor: SystemActor.system(:device_inventory_rollup_db_test)
             )

    refute Enum.any?(writes(), &match?([_table, "TRUNCATE", _key], &1))
    assert_counts()
  end

  test "migration rollback and reapply preserve populated counts", %{prefix: prefix} do
    insert_batch(prefix, 3)
    migrate(:down)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET is_available = false, availability_state = 'unavailable' WHERE starts_with(uid, $1)",
      [prefix]
    )

    assert_counts()
    migrate(:up)
    clear_writes()

    Repo.query!(
      "UPDATE platform.ocsf_devices SET is_available = true, availability_state = 'available' WHERE starts_with(uid, $1)",
      [prefix]
    )

    assert writes() == [
             ["device_inventory_counts", "UPDATE", "available"],
             ["device_inventory_counts", "UPDATE", "unavailable"]
           ]

    assert_counts()
  end

  # An upsert fires its UPDATE trigger before its INSERT trigger. Here the UPDATE makes an
  # available switch an unavailable router, and stops at the router counter another session
  # holds. A concurrent insert of an unavailable device takes the total and waits for the
  # unavailable counter. Released, the upsert's INSERT trigger asks for the total: a
  # deadlock, unless the triggers serialize before their first counter write. Nothing commits.
  @tag :separate_sessions
  test "an upsert's update and insert triggers do not deadlock with a concurrent insert" do
    prefix = prefix()

    holder =
      start_session([
        {"""
         INSERT INTO platform.device_inventory_type_counts (type, count, updated_at)
         VALUES ('router', 0, now())
         ON CONFLICT (type) DO UPDATE SET count = platform.device_inventory_type_counts.count
         """, []}
      ])

    assert {:ran, :ok} = await_session(holder)

    upsert =
      start_session([
        {"SET LOCAL platform.skip_inventory_rollup = 'on'", []},
        {"""
         INSERT INTO platform.ocsf_devices (uid, is_available, type, vendor_name)
         VALUES ($1, true, 'switch', 'Example Devices')
         """, ["#{prefix}existing"]},
        {"SET LOCAL platform.skip_inventory_rollup = 'off'", []},
        {"""
         INSERT INTO platform.ocsf_devices (uid, is_available, type, vendor_name)
         VALUES ($1, false, 'router', 'Example Devices'), ($2, true, 'switch', 'Example Devices')
         ON CONFLICT (uid) DO UPDATE SET is_available = EXCLUDED.is_available, type = EXCLUDED.type
         """, ["#{prefix}existing", "#{prefix}new"]}
      ])

    await_lock_wait(upsert)

    insert =
      start_session([
        {"""
         INSERT INTO platform.ocsf_devices (uid, is_available, type, vendor_name)
         VALUES ($1, false, 'switch', 'Example Devices')
         """, ["#{prefix}concurrent"]}
      ])

    await_lock_wait(insert)
    release_session(holder)

    assert {:ran, :ok} = await_session(upsert)
    release_session(upsert)
    assert {:ran, :ok} = await_session(insert)
    release_session(insert)
  end

  defp prefix, do: "serviceradar:rollup-#{Ecto.UUID.generate()}-"

  # Runs the statements in a transaction on a connection of its own, reports the outcome
  # and rolls back when released. The task is linked to the test, so a failed assertion
  # closes its connection; the lock timeout ends any wait a closed session left behind.
  defp start_session(statements) do
    parent = self()
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :name])

    session =
      Task.async(fn ->
        {:ok, conn} = Postgrex.start_link(Keyword.put(config, :pool_size, 1))

        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "SET LOCAL lock_timeout = #{@wait_ms}", [])
          %{rows: [[backend]]} = Postgrex.query!(tx, "SELECT pg_backend_pid()", [])
          send(parent, {:backend, self(), backend})
          send(parent, {:ran, self(), run_statements(tx, statements)})

          receive do
            :release -> Postgrex.rollback(tx, :released)
          end
        end)
      end)

    task_pid = session.pid
    assert_receive {:backend, ^task_pid, backend}, @wait_ms
    {session, backend}
  end

  defp run_statements(tx, statements) do
    Enum.reduce_while(statements, :ok, fn {sql, params}, :ok ->
      case Postgrex.query(tx, sql, params) do
        {:ok, _result} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp await_session({session, _backend}) do
    pid = session.pid
    assert_receive {:ran, ^pid, result}, @wait_ms
    {:ran, result}
  end

  defp release_session({session, _backend}) do
    send(session.pid, :release)
    assert {:error, :released} = Task.await(session, @wait_ms)
  end

  defp await_lock_wait({session, backend}, attempts \\ 150) do
    pid = session.pid

    receive do
      {:ran, ^pid, result} -> flunk("session finished without waiting: #{inspect(result)}")
    after
      0 -> :ok
    end

    Repo.query!("SELECT pg_stat_clear_snapshot()")
    query = "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1"

    case Repo.query!(query, [backend]).rows do
      [["Lock"]] ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(100)
        await_lock_wait({session, backend}, attempts - 1)

      other ->
        flunk("session never waited on a lock: #{inspect(other)}")
    end
  end

  defp insert_batch(prefix, size) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices (uid, is_available, availability_state, type, vendor_name)
      SELECT $1 || n, true, 'available', 'switch', 'Example Devices'
      FROM generate_series(1, $2::int) n
      """,
      [prefix, size]
    )
  end

  defp clear_writes, do: Repo.query!("TRUNCATE rollup_writes")

  defp writes do
    Repo.query!(
      "SELECT relation, operation, key FROM rollup_writes ORDER BY relation, operation, key"
    ).rows
  end

  defp counts do
    Repo.query!("""
    SELECT 'status', key, value FROM platform.device_inventory_counts WHERE value <> 0
    UNION ALL
    SELECT 'type', type, count FROM platform.device_inventory_type_counts
    UNION ALL
    SELECT 'vendor', vendor_name, count FROM platform.device_inventory_vendor_counts
    ORDER BY 1, 2
    """).rows
  end

  defp assert_counts do
    expected =
      Repo.query!("""
      WITH active AS (
        SELECT * FROM platform.ocsf_devices WHERE deleted_at IS NULL AND source_retired_at IS NULL
      )
      SELECT 'status', 'total', COUNT(*) FROM active HAVING COUNT(*) <> 0
      UNION ALL
      -- Same key as refresh_device_inventory_rollups() after 20261024120000:
      -- available and unavailable stay themselves; every other state, including
      -- the mirror's projection of NULL is_available, is unknown.
      SELECT 'status', CASE availability_state WHEN 'available' THEN 'available' WHEN 'unavailable' THEN 'unavailable' ELSE 'unknown' END,
             COUNT(*) FROM active GROUP BY 2
      UNION ALL
      SELECT 'type', COALESCE(NULLIF(trim(type), ''), 'Unknown'), COUNT(*) FROM active GROUP BY 2
      UNION ALL
      SELECT 'vendor', COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown'), COUNT(*) FROM active GROUP BY 2
      ORDER BY 1, 2
      """).rows

    assert counts() == expected
  end

  defp migrate(direction) do
    Runner.run(Repo, Repo.config(), 20_261_019_150_000, Migration, :forward, direction, direction,
      log: false
    )
  end
end
