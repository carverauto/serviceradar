defmodule ServiceRadar.Inventory.FleetIdentityDictionaryBoundaryDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Migration.Runner
  alias ServiceRadar.Inventory.FleetIdentity
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.GeneralizeFleetIdentityDictionaries, as: Migration
  alias ServiceRadar.Repo.Migrations.WidenFleetOrdinals

  @moduletag :integration
  @migration_version 20_261_016_040_000
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261016040000_generalize_fleet_identity_dictionaries.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  @widen_migration_path Path.expand(
                          "../../../priv/repo/migrations/20261016035900_widen_fleet_ordinals.exs",
                          __DIR__
                        )
  @external_resource @widen_migration_path
  Code.require_file(@widen_migration_path)

  @last_ordinal 4_294_967_295
  @sequence "platform.device_fleet_ordinals_ordinal_seq"
  @lifecycle_triggers ~w(
    trg_clear_restored_identity_purge
    trg_device_fleet_identity_insert
    trg_device_fleet_identity_update
  )
  @protect_triggers ~w(trg_protect_fleet_identity_delete trg_protect_fleet_identity_truncate)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "service components do not allocate ordinals and existing assignments remain reserved" do
    uid = "serviceradar:component-#{Ecto.UUID.generate()}"
    Repo.query!("INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [uid])
    assert {:ok, nil} = FleetIdentity.ensure_device(uid)
    assert FleetIdentity.device_ordinal(uid) == nil

    assert %{rows: []} =
             Repo.query!("SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1", [
               uid
             ])

    # An assignment from an earlier writer remains reserved even outside the device domain.
    assert %{rows: [[reserved]]} =
             Repo.query!(
               "INSERT INTO platform.device_fleet_ordinals (uid) VALUES ($1) RETURNING ordinal",
               [uid]
             )

    assert {:ok, nil} = FleetIdentity.ensure_device(uid)
    assert FleetIdentity.device_ordinal(uid) == nil

    assert %{rows: [[^reserved]]} =
             Repo.query!("SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1", [
               uid
             ])
  end

  test "the last unsigned ordinal, exhausted allocation, and rejected bounds roll back with migration down" do
    suffix = System.unique_integer([:positive])
    last_uid = "sr:dictionary-last-#{suffix}"
    exhausted_uid = "sr:dictionary-exhausted-#{suffix}"
    bounds_uid = "sr:dictionary-bounds-#{suffix}"
    sequence_before = sequence_snapshot()
    epoch_before = FleetIdentity.epoch()
    assignments_before = assignment_snapshot()

    assert sequence_before.settings == %{
             type: "bigint",
             min: 1,
             max: @last_ordinal,
             increment: 1,
             cycle: false
           }

    assert is_binary(epoch_before)

    assert(
      is_nil(assignments_before.max_ordinal) or
        assignments_before.max_ordinal < @last_ordinal
    )

    assert trigger_names() == MapSet.new(@lifecycle_triggers ++ @protect_triggers)

    assert {:error, :boundary_checked} =
             Repo.transaction(fn ->
               Repo.query!("ALTER SEQUENCE #{@sequence} RESTART WITH #{@last_ordinal}")

               Repo.query!("INSERT INTO platform.ocsf_devices (uid, type_id) VALUES ($1, 0)", [
                 last_uid
               ])

               assert FleetIdentity.device_ordinal(last_uid) == @last_ordinal

               assert %{rows: [[@last_ordinal, false]]} =
                        Repo.query!(
                          "SELECT ordinal, tombstoned FROM platform.device_fleet_ordinals WHERE uid = $1",
                          [last_uid]
                        )

               exhausted =
                 rejected("exhausted", fn ->
                   Repo.query!(
                     "INSERT INTO platform.ocsf_devices (uid, type_id) VALUES ($1, 0)",
                     [exhausted_uid]
                   )
                 end)

               assert exhausted.postgres.code == :sequence_generator_limit_exceeded
               assert FleetIdentity.device_ordinal(exhausted_uid) == nil

               Repo.query!(
                 "INSERT INTO platform.ocsf_devices (uid, type_id, deleted_at) VALUES ($1, 0, now())",
                 [bounds_uid]
               )

               for ordinal <- [0, @last_ordinal + 1] do
                 rejected =
                   rejected("bounds_#{ordinal}", fn ->
                     Repo.query!(
                       "INSERT INTO platform.device_fleet_ordinals (uid, ordinal) VALUES ($1, $2)",
                       [bounds_uid, ordinal]
                     )
                   end)

                 assert rejected.postgres.code == :check_violation
                 assert rejected.postgres.constraint == "device_fleet_ordinals_u32"
               end

               assert %{rows: []} =
                        Repo.query!(
                          "SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1",
                          [bounds_uid]
                        )

               :ok =
                 Runner.run(
                   Repo,
                   Repo.config(),
                   @migration_version,
                   Migration,
                   :forward,
                   :down,
                   :down,
                   log: false
                 )

               :ok =
                 Runner.run(
                   Repo,
                   Repo.config(),
                   20_261_016_035_900,
                   WidenFleetOrdinals,
                   :forward,
                   :down,
                   :down,
                   log: false
                 )

               assert sequence_snapshot().settings == sequence_before.settings
               assert FleetIdentity.epoch() == epoch_before
               assert FleetIdentity.device_ordinal(last_uid) == @last_ordinal

               assert %{rows: [[true]]} =
                        Repo.query!("""
                        SELECT EXISTS (
                          SELECT 1 FROM information_schema.columns
                          WHERE table_schema = 'platform'
                            AND table_name = 'ocsf_devices'
                            AND column_name = 'identity_purged_at'
                        )
                        """)

               assert trigger_names() == MapSet.new(@protect_triggers)

               Repo.rollback(:boundary_checked)
             end)

    assert sequence_snapshot() == sequence_before
    assert FleetIdentity.epoch() == epoch_before
    assert assignment_snapshot() == assignments_before
    assert trigger_names() == MapSet.new(@lifecycle_triggers ++ @protect_triggers)

    assert %{rows: []} =
             Repo.query!(
               "SELECT uid FROM platform.ocsf_devices WHERE uid = ANY($1::text[])",
               [[last_uid, exhausted_uid, bounds_uid]]
             )
  end

  defp rejected(name, fun) do
    Repo.query!("SAVEPOINT #{name}")

    error =
      assert_raise Postgrex.Error, fn ->
        fun.()
      end

    Repo.query!("ROLLBACK TO SAVEPOINT #{name}")
    error
  end

  defp sequence_snapshot do
    %{rows: [[type, min, max, increment, cycle, last_value, called, log_count]]} =
      Repo.query!("""
      SELECT format_type(seq.seqtypid, NULL),
             seq.seqmin,
             seq.seqmax,
             seq.seqincrement,
             seq.seqcycle,
             sequence.last_value,
             sequence.is_called,
             sequence.log_cnt
      FROM pg_sequence AS seq
      CROSS JOIN #{@sequence} AS sequence
      WHERE seq.seqrelid = '#{@sequence}'::regclass
      """)

    %{
      settings: %{type: type, min: min, max: max, increment: increment, cycle: cycle},
      state: %{last_value: last_value, is_called: called, log_cnt: log_count}
    }
  end

  defp assignment_snapshot do
    %{rows: [[count, max_ordinal]]} =
      Repo.query!("SELECT count(*), max(ordinal) FROM platform.device_fleet_ordinals")

    %{count: count, max_ordinal: max_ordinal}
  end

  defp trigger_names do
    names = @lifecycle_triggers ++ @protect_triggers

    %{rows: rows} =
      Repo.query!(
        """
        SELECT tgname
        FROM pg_trigger
        WHERE tgrelid IN ('platform.ocsf_devices'::regclass, 'platform.device_fleet_ordinals'::regclass)
          AND NOT tgisinternal
          AND tgname = ANY($1::text[])
        """,
        [names]
      )

    MapSet.new(Enum.map(rows, &hd/1))
  end
end
