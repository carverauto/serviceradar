defmodule ServiceRadar.Inventory.AvailabilityProgressionIntegrationTest do
  @moduledoc """
  Automatic progression of merged availability against the real schema
  (`add-merged-device-availability`, design Decision 10, "Automatic progression"): core
  moves `legacy` to `shadow` and cuts over by itself once every readiness condition
  holds, an unmet condition blocks the cutover and is named in the settings row, a hold
  rolls back through the same restore an operator's rollback uses, a pin wins over the
  stored control, and two runs racing on the same step switch once.

  Every fixture is invented (192.0.2.0/24, SITE01-style names, generated ids). The
  install is emptied inside the sandbox transaction (devices soft-deleted, sweep groups
  disabled), so each test sees only what it creates and the transaction rolls it back.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import ServiceRadar.TestSupport.AvailabilityFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Availability.CutoverWorker
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.ModeControl
  alias ServiceRadar.Inventory.Availability.Operator
  alias ServiceRadar.Inventory.Availability.ProgressionWorker
  alias ServiceRadar.Inventory.Availability.Readiness
  alias ServiceRadar.Inventory.Availability.ShadowEntryWorker
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @workers [ShadowEntryWorker, CutoverWorker, ProgressionWorker, Transitions]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:availability_progression_test)}
  end

  describe "automatic progression" do
    test "a zero-device install reaches authoritative with no operator step" do
      empty_install!()

      enter_shadow_and_resolve!()
      cut_over_automatically!()

      assert cutover_jobs() == [{"announce", "available"}]
      assert {:ok, :none} = ProgressionWorker.run()
      assert Mode.current() == :authoritative
    end

    test "an install in legacy whose conditions hold reaches authoritative with no operator step",
         %{actor: actor} do
      empty_install!()
      controller = create_device!(actor, "192.0.2.200")
      silent = create_device!(actor, "192.0.2.201")
      {:ok, _} = Availability.record_evidence([wifi(controller.uid, :up, minutes_ago(2))])
      set_column!(controller.uid, false)
      {group, agent_id} = sweep_group!(actor)

      enter_shadow_and_resolve!()
      backdate_shadow_entry!("1 hour")
      # The group ran before the entry and again after it.
      execution!(group, agent_id, "completed", "2 hours")
      execution!(group, agent_id, "completed", "30 minutes")
      cut_over_automatically!()

      assert {true, "available", _rule} = device_state(controller.uid)
      assert {_available, "unknown", "no_evidence"} = device_state(silent.uid)

      # The same switch as an operator's: one announcement, nothing per device.
      assert cutover_jobs() == [{"announce", "available"}]
      assert transition_job_count() == 0
    end
  end

  describe "readiness gating" do
    # Each blocker leaves exactly one condition unmet on an otherwise ready install.
    @blockers [
      {"capture_backfill", :backfill},
      {"shadow_resolve", :resolve},
      {"invalidation_backlog", :backlog},
      {"sweep_groups", :sweep},
      {"policy_violations", :violation}
    ]

    for {condition, blocker} <- @blockers do
      test "an unmet #{condition} blocks the cutover and is named", %{actor: actor} do
        ready_shadow!()
        block!(unquote(blocker), actor)

        assert {:ok, step} = ProgressionWorker.run()
        assert step in [:none, :resolve]
        assert Mode.current() == :shadow
        assert cutover_jobs() == []
        assert %{"ready" => false, "unmet" => [unquote(condition)]} = stored_readiness(actor)
      end
    end

    test "unmet conditions 24 hours after entering shadow raise a health warning; the cutover clears it" do
      ready_shadow!()
      backdate_shadow_entry!("25 hours")
      block!(:backlog, nil)

      assert {:ok, :none} = ProgressionWorker.run()
      assert Mode.current() == :shadow
      assert %{new_state: :unhealthy, metadata: metadata} = readiness_health()
      assert metadata["unmet"] == ["invalidation_backlog"]

      Repo.query!("DELETE FROM platform.availability_invalidations")
      assert {:ok, :enter_cutover, %{from: :shadow, to: :cutover}} = ProgressionWorker.run()
      assert %{new_state: :healthy} = readiness_health()
    end
  end

  describe "holds" do
    test "hold_legacy from authoritative restores is_available from the compatibility table",
         %{actor: actor} do
      device = authoritative_with_recovered_device!(actor)

      assert {:ok, _setting} = ModeControl.set(:hold_legacy, actor: actor)
      assert {:ok, :enter_legacy, %{from: :authoritative, to: :legacy}} = ProgressionWorker.run()
      perform_waiting!(CutoverWorker, "restore")

      assert {false, "unavailable", "legacy_mirror"} = device_state(device.uid)
      assert {:ok, :none} = ProgressionWorker.run()
      assert Mode.current() == :legacy
    end

    test "a pruned restore is re-enqueued under auto and the snapshot is kept",
         %{actor: actor} do
      device = authoritative_with_recovered_device!(actor)
      assert false == legacy_value(device.uid)

      assert {:ok, _setting} = ModeControl.set(:hold_legacy, actor: actor)
      assert {:ok, :enter_legacy, %{from: :authoritative, to: :legacy}} = ProgressionWorker.run()

      # Discarded, then pruned: no job row, and the restore never ran.
      delete_jobs!()

      assert {:ok, _setting} = ModeControl.set(:auto, actor: actor)
      assert {:ok, :restore} = ProgressionWorker.run()
      assert Mode.current() == :legacy
      assert cutover_jobs() == [{"restore", "available"}]
      assert false == legacy_value(device.uid)

      assert {:ok, :none} = ProgressionWorker.run()
      assert Mode.current() == :legacy
      assert false == legacy_value(device.uid)
    end

    test "hold_shadow from authoritative returns to shadow through legacy once the restore is done",
         %{actor: actor} do
      device = authoritative_with_recovered_device!(actor)

      assert {:ok, _setting} = ModeControl.set(:hold_shadow, actor: actor)
      assert {:ok, :enter_legacy, %{from: :authoritative, to: :legacy}} = ProgressionWorker.run()
      assert {:ok, :none} = ProgressionWorker.run()

      perform_waiting!(CutoverWorker, "restore")
      assert {:ok, :enter_shadow, %{from: :legacy, to: :shadow}} = ProgressionWorker.run()
      assert {false, "unavailable", "legacy_mirror"} = device_state(device.uid)

      # Held in shadow even with every condition met.
      perform_waiting!(ShadowEntryWorker, "resolve")
      assert {:ok, :none} = ProgressionWorker.run()
      assert %{"ready" => true} = stored_readiness(actor)
      assert Mode.current() == :shadow
    end
  end

  describe "support switches" do
    test "a refused switch to cutover leaves a hold in place; an accepted one releases it",
         %{actor: actor} do
      empty_install!()
      assert {:ok, _setting} = ModeControl.set(:hold_legacy, actor: actor)

      assert {{:error, {:unsupported_switch, :legacy, :cutover}}, _output} =
               with_io(fn -> Operator.switch("cutover") end)

      assert {:ok, %{mode_control: :hold_legacy}} = ModeControl.read(actor: actor)
      assert {:ok, :none} = ProgressionWorker.run()
      assert Mode.current() == :legacy

      # From shadow the switch succeeds and sets auto in the same transaction.
      set_settings!("shadow", "hold_legacy")

      assert {{:ok, %{from: :shadow, to: :cutover}}, _output} =
               with_io(fn -> Operator.switch("cutover") end)

      assert {:ok, %{mode: :cutover, mode_control: :auto}} = ModeControl.read(actor: actor)
    end
  end

  describe "the environment pin" do
    setup do
      previous = Application.get_env(:serviceradar_core, ModeControl)
      on_exit(fn -> restore_env(previous) end)
      :ok
    end

    test "a pin wins over the stored control, and the stored control cannot be edited while pinned" do
      editor = %{
        id: Ash.UUID.generate(),
        role: :admin,
        permissions: MapSet.new(["settings.networks.manage"])
      }

      empty_install!()
      enter_shadow_and_resolve!()
      assert {:ok, _setting} = ModeControl.set(:hold_shadow, actor: editor)

      Application.put_env(:serviceradar_core, ModeControl, pin: "hold_legacy")
      assert {:ok, :enter_legacy, %{from: :shadow, to: :legacy}} = ProgressionWorker.run()

      assert {:ok, %{mode_control: :hold_shadow, mode_control_pin: "hold_legacy"}} =
               ModeControl.read(actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} = ModeControl.set(:auto, actor: editor)

      # A pin that is not a control holds the mode where it is.
      Application.put_env(:serviceradar_core, ModeControl, pin: "cutover")
      assert {{:ok, :none}, log} = with_log(&ProgressionWorker.run/0)
      assert log =~ "holding the mode"
      assert Mode.current() == :legacy
    end
  end

  describe "concurrent runs" do
    # Real concurrent transactions on committed settings; restored after.
    @tag sandbox: :unboxed
    test "two runs that both decided to roll back switch once and keep the restore" do
      parent = self()
      supervisor = start_supervised!(Task.Supervisor)

      try do
        delete_jobs!()
        set_settings!("authoritative", "hold_legacy")

        # An admitted writer holds the switch lock shared, so both runs read
        # `authoritative` and decide to roll back before either can switch.
        writer =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Repo.transaction(fn ->
              Mode.admit()
              send(parent, {:admitted, self()})

              receive do
                :release -> :ok
              after
                10_000 -> raise "the test did not release the writer"
              end
            end)
          end)

        assert_receive {:admitted, writer_pid}, 5_000

        runs =
          for _run <- 1..2,
              do: Task.Supervisor.async_nolink(supervisor, &ProgressionWorker.run/0)

        assert runs
               |> Task.yield_many(1_000)
               |> Enum.all?(fn {_task, result} -> is_nil(result) end)

        send(writer_pid, :release)
        assert {:ok, {:ok, _}} = Task.yield(writer, 5_000)

        results = Enum.map(runs, &Task.await(&1, 15_000))

        assert Enum.sort(results) == [
                 {:ok, :enter_legacy, %{from: :authoritative, to: :legacy}},
                 {:ok, :enter_legacy, %{from: :legacy, to: :legacy}}
               ]

        assert Mode.current() == :legacy
        assert cutover_jobs() == [{"restore", "available"}]
      after
        set_settings!("legacy", "auto")
        delete_jobs!()
      end
    end
  end

  # -- fixtures -------------------------------------------------------------------------

  # Inside the sandbox transaction: no live device, no enabled sweep group, nothing
  # waiting to resolve, and the settings row as a fresh install has it.
  defp empty_install! do
    set_settings!("legacy", "auto")

    Repo.query!(
      "UPDATE platform.ocsf_devices SET deleted_at = (now() AT TIME ZONE 'utc') WHERE deleted_at IS NULL"
    )

    Repo.query!("DELETE FROM platform.device_agent_availability")
    Repo.query!("DELETE FROM platform.availability_invalidations")
    Repo.query!("DELETE FROM platform.device_availability_shadow")
    Repo.query!("UPDATE platform.sweep_groups SET enabled = false WHERE enabled")
    delete_jobs!()
  end

  # Every job of these workers except the rollup rebuild a migration enqueued.
  defp delete_jobs! do
    Repo.query!(
      """
      DELETE FROM platform.oban_jobs
      WHERE worker = ANY($1::text[]) AND args ->> 'phase' IS DISTINCT FROM 'refresh_rollups'
      """,
      [Enum.map(@workers, &inspect/1)]
    )
  end

  defp set_settings!(mode, control) do
    Repo.query!(
      """
      UPDATE platform.availability_settings
      SET mode = $1, mode_control = $2, mode_control_pin = NULL, expiry_watermark = NULL,
          shadow_entered_at = NULL, shadow_resolved_at = NULL, readiness = NULL,
          readiness_checked_at = NULL
      WHERE singleton
      """,
      [mode, control]
    )
  end

  defp enter_shadow_and_resolve! do
    assert {:ok, :enter_shadow, %{from: :legacy, to: :shadow}} = ProgressionWorker.run()
    perform_waiting!(ShadowEntryWorker, "resolve")
  end

  defp cut_over_automatically! do
    assert {:ok, :enter_cutover, %{from: :shadow, to: :cutover}} = ProgressionWorker.run()
    perform_waiting!(CutoverWorker, "reconcile")
    assert Mode.current() == :authoritative
  end

  defp ready_shadow! do
    empty_install!()
    enter_shadow_and_resolve!()
    backdate_shadow_entry!("1 hour")
  end

  # A device whose legacy value is false and whose controller reports it up.
  defp authoritative_with_recovered_device!(actor) do
    empty_install!()
    device = create_device!(actor, "192.0.2.210")
    {:ok, _} = Availability.record_evidence([wifi(device.uid, :up, minutes_ago(2))])
    set_column!(device.uid, false)

    enter_shadow_and_resolve!()
    cut_over_automatically!()
    assert {true, "available", _rule} = device_state(device.uid)
    device
  end

  defp block!(:backfill, actor) do
    # An unreachable ledger row the stage-a backfill has not counted yet.
    device = create_device!(actor, "192.0.2.220")
    ledger_row!(actor, device, "agent-a", false, minutes_ago(5))

    Repo.query!(
      "UPDATE platform.device_agent_availability SET consecutive_down = 0 WHERE device_uid = $1",
      [device.uid]
    )
  end

  defp block!(:resolve, _actor) do
    Repo.query!("UPDATE platform.availability_settings SET shadow_resolved_at = NULL")
  end

  defp block!(:backlog, _actor) do
    Repo.query!(
      """
      INSERT INTO platform.availability_invalidations (device_uid)
      SELECT 'sr:progression-' || n FROM generate_series(1, $1::int) AS n
      """,
      [Readiness.backlog_threshold() + 1]
    )
  end

  defp block!(:sweep, actor) do
    # Active (ran in the last 24 hours), but only before the entry.
    {group, agent_id} = sweep_group!(actor)
    execution!(group, agent_id, "completed", "2 hours")
  end

  defp block!(:violation, actor) do
    device = create_device!(actor, "192.0.2.221")

    Repo.query!(
      """
      INSERT INTO platform.device_availability_shadow (device_uid, availability_state, agents)
      VALUES ($1, 'available', '{"up": 1, "total": 1, "policy_violation": 1}')
      ON CONFLICT (device_uid) DO UPDATE SET agents = EXCLUDED.agents
      """,
      [device.uid]
    )
  end

  defp backdate_shadow_entry!(interval) do
    Repo.query!(
      "UPDATE platform.availability_settings SET shadow_entered_at = shadow_entered_at - $1::interval",
      [interval]
    )
  end

  defp execution!(group, agent_id, status, started_ago) do
    Repo.query!(
      """
      INSERT INTO platform.sweep_group_executions (sweep_group_id, agent_id, status, started_at)
      VALUES ($1, $2, $3, date_trunc('second', now() AT TIME ZONE 'utc') - $4::interval)
      """,
      [Ecto.UUID.dump!(group.id), agent_id, status, started_ago]
    )
  end

  defp set_column!(uid, value) do
    Repo.query!("UPDATE platform.ocsf_devices SET is_available = $2 WHERE uid = $1", [uid, value])
  end

  # Runs the waiting job of `phase` as Oban would, and marks it completed.
  defp perform_waiting!(worker, phase) do
    assert :ok = perform_job(worker, %{"phase" => phase})

    Repo.query!(
      """
      UPDATE platform.oban_jobs SET state = 'completed', completed_at = now() AT TIME ZONE 'utc'
      WHERE worker = $1 AND args ->> 'phase' = $2
        AND state IN ('available', 'scheduled', 'retryable')
      """,
      [inspect(worker), phase]
    )
  end

  defp restore_env(nil), do: Application.delete_env(:serviceradar_core, ModeControl)
  defp restore_env(previous), do: Application.put_env(:serviceradar_core, ModeControl, previous)

  # -- reads ----------------------------------------------------------------------------

  defp stored_readiness(actor) do
    {:ok, setting} = ModeControl.read(actor: actor)
    setting.readiness
  end

  defp readiness_health do
    {:ok, event} = HealthTracker.current_status(:core, "availability_cutover_readiness")
    event
  end

  defp cutover_jobs, do: waiting_jobs(CutoverWorker) -- [{"refresh_rollups", "available"}]

  defp waiting_jobs(worker) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT args ->> 'phase', state FROM platform.oban_jobs
        WHERE worker = $1 AND state IN ('available', 'scheduled') ORDER BY 1
        """,
        [inspect(worker)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp transition_job_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.oban_jobs WHERE worker = $1", [
        inspect(Transitions)
      ])

    count
  end
end
