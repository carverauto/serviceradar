defmodule ServiceRadar.Inventory.AvailabilityCutoverIntegrationTest do
  @moduledoc """
  Stage c of `add-merged-device-availability` against the real schema: the drained
  switch to `cutover` seeds the compatibility table, the reconciliation re-resolves every
  device with no per-device side effect, `authoritative` emits each transition once
  through the outbox, the legacy writers keep computing into the compatibility table
  only, and the rollback to `legacy` restores `is_available` from it.

  Every fixture is invented (192.0.2.0/24, SITE01-style names, generated ids).
  """

  use ServiceRadar.DataCase, async: false

  import ServiceRadar.TestSupport.AvailabilityFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Availability.CutoverWorker
  alias ServiceRadar.Inventory.Availability.LegacyWrites
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:availability_cutover_test)}
  end

  describe "cutover and reconciliation" do
    test "seeds the compatibility table under the switch and reconciles every device without side effects",
         %{actor: actor} do
      devices = cut_over!(actor)

      # A reconciled device is decided from its current inputs; the ledger is untouched.
      assert {true, "available", "highest_class"} = device_state(devices.controller.uid)

      assert %{kind: "wifi_map", conflict: true, agents: %{"down" => 1, "up" => 0}} =
               decision(devices.controller.uid)

      assert ledger(devices.controller.uid) == devices.controller_ledger

      # No evidence: unknown, keeping the last decided boolean (false when it had none).
      assert {true, "unknown", "no_evidence"} = device_state(devices.silent.uid)
      assert {false, "unknown", "no_evidence"} = device_state(devices.nulled.uid)

      # Down evidence ingested during cutover is not overwritten from the older shadow.
      assert {false, "unavailable", _rule} = device_state(devices.superseded.uid)

      # Nothing per device was emitted in cutover; the counters follow the state.
      assert transition_jobs() == []
      assert Mode.current() == :authoritative
      assert {"announce", "available"} in cutover_jobs()
      assert rollup_counts() == state_counts()
    end
  end

  describe "rollback to legacy" do
    test "restores is_available from the compatibility table and the mirror re-derives the state",
         %{actor: actor} do
      devices = cut_over!(actor)
      evidence_before = evidence_count(devices.controller.uid)

      assert {:ok, %{from: :authoritative, to: :legacy}} = Mode.enter_legacy()
      assert cutover_jobs() == [{"restore", "available"}]
      assert :ok = perform_job(CutoverWorker, %{"phase" => "restore"})

      assert {false, "unavailable", "legacy_mirror"} = device_state(devices.controller.uid)
      assert {true, "available", "legacy_mirror"} = device_state(devices.silent.uid)
      assert {nil, "unknown", _rule} = device_state(devices.nulled.uid)
      assert {true, "available", "legacy_mirror"} = device_state(devices.superseded.uid)
      assert decision(devices.controller.uid).agents == nil

      # Evidence and per-agent results are retained.
      assert evidence_count(devices.controller.uid) == evidence_before
      assert ledger(devices.controller.uid) == devices.controller_ledger
      assert rollup_counts() == state_counts()
    end
  end

  describe "authoritative" do
    test "a controller's up holds through failing sweeps; only the compatibility table flips",
         %{actor: actor} do
      set_mode!("authoritative")
      device = create_device!(actor, "192.0.2.190")
      {group, agent_id} = sweep_group!(actor)

      {:ok, _} = Availability.record_evidence([wifi(device.uid, :up, minutes_ago(5))])
      assert {true, "available", "highest_class"} = device_state(device.uid)
      changed_at = changed_at(device.uid)
      transitions_before = transition_jobs()

      for minutes <- [4, 3, 2, 1] do
        sweep!(actor, group, agent_id, "192.0.2.190", false, minutes_ago(minutes))
      end

      assert {true, "available", "highest_class"} = device_state(device.uid)
      assert changed_at(device.uid) == changed_at
      assert %{conflict: true, agents: %{"down" => 1}} = decision(device.uid)

      # The legacy hysteresis still runs, into the compatibility table.
      assert legacy_value(device.uid) == false
      assert transitions_only(transition_jobs() -- transitions_before) == []
    end

    test "a transition writes one outbox job in the resolving transaction; a rollback writes none",
         %{actor: actor} do
      set_mode!("authoritative")
      device = create_device!(actor, "192.0.2.191")

      {:ok, _} = Availability.record_evidence([wifi(device.uid, :up, minutes_ago(3))])

      assert [%{"uid" => uid, "from" => "unknown", "to" => "available"}] =
               transitions_only(transition_jobs())

      assert uid == device.uid

      # Nothing changed: the device row is not rewritten and no job is written.
      version = device_xmin(device.uid)
      jobs = transition_jobs()
      {:ok, _} = Availability.resolve_devices([device.uid])
      assert device_xmin(device.uid) == version
      assert transition_jobs() == jobs

      # A conflict-only change updates the row with no transition.
      confirmed_down!(actor, device, "agent-a")
      {:ok, _} = Availability.resolve_devices([device.uid])
      assert %{conflict: true} = decision(device.uid)
      assert [%{"transitions" => [], "invalidated" => [^uid]}] = transition_jobs() -- jobs

      # A resolution that rolls back writes neither the device nor the outbox.
      jobs = transition_jobs()

      {:error, :abort} =
        Repo.transaction(fn ->
          {:ok, _} = Availability.record_evidence([wifi(device.uid, :down, minutes_ago(0))])
          Repo.rollback(:abort)
        end)

      assert {true, "available", _rule} = device_state(device.uid)
      assert transition_jobs() == jobs
    end

    test "the sync path writes its availability to the compatibility table only", %{actor: actor} do
      set_mode!("authoritative")
      sync!(actor, "192.0.2.192", false)
      device = device_by_ip("192.0.2.192")

      # A new device carries its legacy value in the compatibility table.
      assert legacy_value(device.uid) == false
      drain!()
      assert {false, "unknown", "no_evidence"} = device_state(device.uid)

      {:ok, _} = Availability.record_evidence([wifi(device.uid, :up, minutes_ago(1))])
      assert {true, "available", _rule} = device_state(device.uid)

      # A later sync reporting down changes the legacy value, not the device.
      sync!(actor, "192.0.2.192", false)
      sync!(actor, "192.0.2.192", true)
      sync!(actor, "192.0.2.192", false)
      assert legacy_value(device.uid) == false
      assert {true, "available", _rule} = device_state(device.uid)
    end
  end

  describe "the switch drains writers" do
    # Real concurrent transactions, so the rows and the mode commit; restored after.
    @tag sandbox: :unboxed
    test "a legacy writer admitted before the switch lands before it, and the seed sees it",
         %{actor: actor} do
      parent = self()
      supervisor = start_supervised!(Task.Supervisor)
      device = create_device!(actor, "192.0.2.195")

      try do
        set_mode!("shadow")

        writer =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Repo.transaction(fn ->
              mode = LegacyWrites.admit()
              send(parent, {:admitted, mode, self()})

              receive do
                :write -> :ok
              after
                10_000 -> raise "the test did not release the writer"
              end

              Repo.query!(
                "UPDATE platform.ocsf_devices SET is_available = false WHERE uid = $1",
                [
                  device.uid
                ]
              )
            end)
          end)

        assert_receive {:admitted, :shadow, writer_pid}, 5_000
        switch = Task.Supervisor.async_nolink(supervisor, fn -> Mode.enter_cutover() end)

        # The switch cannot commit while the admitted writer is open.
        assert Task.yield(switch, 500) == nil
        assert Mode.current() == :shadow

        send(writer_pid, :write)
        assert {:ok, {:ok, _}} = Task.yield(writer, 5_000)
        assert {:ok, {:ok, %{from: :shadow, to: :cutover}}} = Task.yield(switch, 15_000)

        # The writer's legacy value is in the compatibility table, and later writers
        # are admitted under cutover.
        assert legacy_value(device.uid) == false

        assert {:ok, :cutover} = Repo.transaction(fn -> LegacyWrites.admit() end)
      after
        set_mode!("legacy")

        Repo.query!(
          "DELETE FROM platform.oban_jobs WHERE worker = $1 AND args ->> 'phase' <> 'refresh_rollups'",
          [inspect(CutoverWorker)]
        )

        Repo.query!("DELETE FROM platform.availability_invalidations WHERE device_uid = $1", [
          device.uid
        ])

        TestSupport.delete_device_fixtures!([device.uid])
      end
    end
  end

  # -- fixtures -------------------------------------------------------------------------

  # Four devices, cut over from shadow and reconciled:
  #   controller - controller up, one confirmed-down agent, legacy value false;
  #   silent     - no evidence, legacy value true;
  #   nulled     - no evidence, legacy value NULL;
  #   superseded - shadow said available; a controller down arrives during cutover.
  defp cut_over!(actor) do
    controller = create_device!(actor, "192.0.2.180")
    silent = create_device!(actor, "192.0.2.181")
    nulled = create_device!(actor, "192.0.2.182")
    superseded = create_device!(actor, "192.0.2.183")

    set_mode!("shadow")
    {:ok, _} = Availability.record_evidence([wifi(controller.uid, :up, minutes_ago(2))])
    confirmed_down!(actor, controller, "agent-a")
    {:ok, _} = Availability.record_evidence([wifi(superseded.uid, :up, minutes_ago(2))])

    set_column!(controller.uid, false)
    set_column!(nulled.uid, nil)
    controller_ledger = ledger(controller.uid)

    assert {:ok, %{from: :shadow, to: :cutover}} = Mode.enter_cutover()
    assert legacy_value(controller.uid) == false
    assert legacy_value(silent.uid) == true
    assert legacy_value(nulled.uid) == nil
    assert cutover_jobs() == [{"reconcile", "available"}]

    # Ingestion keeps running in cutover, with every side effect suppressed.
    {:ok, _} = Availability.record_evidence([wifi(superseded.uid, :down, minutes_ago(0))])
    assert {_available, "unavailable", _rule} = device_state(superseded.uid)

    assert :ok = perform_job(CutoverWorker, %{"phase" => "reconcile"})

    %{
      controller: controller,
      silent: silent,
      nulled: nulled,
      superseded: superseded,
      controller_ledger: controller_ledger
    }
  end

  defp set_column!(uid, value) do
    Repo.query!("UPDATE platform.ocsf_devices SET is_available = $2 WHERE uid = $1", [uid, value])
  end

  defp sync!(actor, ip, available?) do
    update = %{
      "ip" => ip,
      "hostname" => "sync-" <> String.replace(ip, ".", "-") <> ".example.com",
      "source" => "netbox",
      "is_available" => available?,
      "metadata" => %{}
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)
  end

  # -- reads ----------------------------------------------------------------------------

  defp decision(uid) do
    %{rows: [[decided_by, conflict, agents]]} =
      Repo.query!(
        """
        SELECT availability_decided_by, availability_conflict, availability_agents
        FROM platform.ocsf_devices WHERE uid = $1
        """,
        [uid]
      )

    %{kind: decided_by["source_kind"], conflict: conflict, agents: agents}
  end

  defp changed_at(uid) do
    %{rows: [[changed_at]]} =
      Repo.query!("SELECT availability_changed_at FROM platform.ocsf_devices WHERE uid = $1", [
        uid
      ])

    changed_at
  end

  defp device_xmin(uid) do
    %{rows: [[xmin]]} =
      Repo.query!("SELECT xmin::text FROM platform.ocsf_devices WHERE uid = $1", [uid])

    xmin
  end

  defp device_by_ip(ip) do
    %{rows: [[uid]]} =
      Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE ip = $1 AND deleted_at IS NULL", [
        ip
      ])

    %{uid: uid}
  end

  defp evidence_count(uid) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.device_availability_evidence WHERE device_uid = $1",
        [uid]
      )

    count
  end

  defp transition_jobs do
    %{rows: rows} =
      Repo.query!(
        "SELECT args FROM platform.oban_jobs WHERE worker = $1 ORDER BY id",
        [inspect(Transitions)]
      )

    Enum.map(rows, &hd/1)
  end

  defp transitions_only(jobs), do: Enum.flat_map(jobs, &Map.get(&1, "transitions", []))

  defp cutover_jobs do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT args ->> 'phase', state FROM platform.oban_jobs
        WHERE worker = $1 AND args ->> 'phase' <> 'refresh_rollups'
          AND state IN ('available', 'scheduled') ORDER BY 1
        """,
        [inspect(CutoverWorker)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp rollup_counts do
    %{rows: rows} =
      Repo.query!("""
      SELECT key, value FROM platform.device_inventory_counts
      WHERE key IN ('available', 'unavailable', 'unknown') AND value <> 0
      """)

    Map.new(rows, &List.to_tuple/1)
  end

  defp state_counts do
    %{rows: rows} =
      Repo.query!("""
      SELECT availability_state, count(*) FROM platform.ocsf_devices
      WHERE deleted_at IS NULL AND source_retired_at IS NULL
      GROUP BY availability_state
      """)

    Map.new(rows, &List.to_tuple/1)
  end
end
