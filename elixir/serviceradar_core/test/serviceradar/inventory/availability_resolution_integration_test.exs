defmodule ServiceRadar.Inventory.AvailabilityResolutionIntegrationTest do
  @moduledoc """
  Merged device availability resolution against the real schema
  (`add-merged-device-availability`): the resolver writes the device row on change from
  the write paths, the invalidation log and the expiry job, emits each transition once
  through the outbox, and never writes the per-agent ledger; the legacy writers keep
  computing into the compatibility table only.

  Every fixture is invented (192.0.2.0/24, SITE01-style names, generated ids).
  """

  use ServiceRadar.DataCase, async: false

  import ServiceRadar.TestSupport.AvailabilityFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Availability.ExpiryWorker
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Inventory.Availability.ResolverWorker
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Inventory.Availability.VantageExpectations
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:availability_resolution_test)}
  end

  describe "write paths" do
    test "a controller's up holds through failing sweeps; only the compatibility table flips",
         %{actor: actor} do
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
      device = create_device!(actor, "192.0.2.191")

      {:ok, _} = Availability.record_evidence([wifi(device.uid, :up, minutes_ago(3))])

      assert [%{"uid" => uid, "from" => "unknown", "to" => "available"}] =
               Enum.filter(transitions_only(transition_jobs()), &(&1["uid"] == device.uid))

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

  describe "resolver worker" do
    test "re-resolves validation scans, a pin change and a new negative control without new evidence",
         %{actor: actor} do
      device = create_device!(actor, "192.0.2.120")

      ledger_row!(actor, device, "agent-b", true, minutes_ago(1))
      failing = ledger_row!(actor, device, "agent-a", false, minutes_ago(3))
      update_ledger!(failing, actor, %{is_available: false, checked_at: minutes_ago(2)})
      ledger_before = ledger(device.uid)

      drain!()

      assert %{state: "available", agents: %{"up" => 1, "down" => 1}, conflict: false} =
               decision(device.uid)

      pin!(actor, device, "agent-a")
      drain!()

      assert %{state: "unavailable", reporter: "agent-a", conflict: true} = decision(device.uid)

      check = enabled_check!(actor)
      control = vantage_input("agent-a", "blocked")
      assert VantageExpectations.materialize(check, [control], [device.uid]) == 1
      drain!()

      assert %{
               state: "available",
               reporter: "agent-b",
               invalid_pin: true,
               agents: %{"blocked_verified" => 1, "total" => 1}
             } = decision(device.uid)

      # Resolution reads the per-agent ledger and never writes it.
      assert ledger(device.uid) == ledger_before
    end

    test "a created or restored device is appended, whichever path restores it",
         %{actor: actor} do
      restored = create_device!(actor, "192.0.2.122")
      drain!()
      created = create_device!(actor, "192.0.2.123")

      assert invalidation_uids() == [created.uid]

      # A tombstone and the raw restore any writer may issue.
      for deleted_at <- ["(now() AT TIME ZONE 'utc')", "NULL"] do
        Repo.query!(
          "UPDATE platform.ocsf_devices SET deleted_at = #{deleted_at} WHERE uid = $1",
          [
            restored.uid
          ]
        )
      end

      assert invalidation_uids() == [created.uid, restored.uid]
    end

    test "a sweep group's interval change or deletion appends its devices",
         %{actor: actor} do
      device = create_device!(actor, "192.0.2.124")
      {group, agent_id} = sweep_group!(actor)
      sweep!(actor, group, agent_id, "192.0.2.124", true, minutes_ago(1))

      set_interval = fn interval ->
        Repo.query!(~s(UPDATE platform.sweep_groups SET "interval" = $1 WHERE id::text = $2), [
          interval,
          group.id
        ])
      end

      set_interval.("5m")
      drain!()
      set_interval.("5m")
      assert invalidation_uids() == []

      set_interval.("2h")
      assert invalidation_uids() == [device.uid]

      Repo.query!("DELETE FROM platform.sweep_groups WHERE id::text = $1", [group.id])
      assert invalidation_uids() == [device.uid, device.uid]
    end

    test "a pass resolves at most 500 devices and re-appends the rest" do
      drain!()
      uids = for n <- 1..501, do: "sr:absent-#{String.pad_leading(Integer.to_string(n), 4, "0")}"
      append!(uids ++ Enum.take(uids, 3))

      assert %{claimed: 504} = ResolverWorker.pass()
      assert invalidation_uids() == [List.last(uids)]
    end
  end

  describe "expiry" do
    test "an expired self-report and an aged-out agent result re-resolve; fresh evidence is untouched",
         %{actor: actor} do
      liveness = create_device!(actor, "192.0.2.130")
      probed = create_device!(actor, "192.0.2.131")
      fresh = create_device!(actor, "192.0.2.132")

      for device <- [liveness, fresh] do
        {:ok, _} =
          Availability.record_evidence([
            %{
              device_uid: device.uid,
              source_kind: "agent_liveness",
              reporter_agent_id: "agent-host",
              state: :up,
              observed_at: DateTime.utc_now(),
              ttl_seconds: 60
            }
          ])
      end

      # A per-agent result without a sweep group is fresh for 2 hours.
      ledger_row!(
        actor,
        probed,
        "agent-a",
        true,
        DateTime.shift(DateTime.utc_now(), minute: -119)
      )

      Availability.resolve_devices([probed.uid])

      for device <- [liveness, probed, fresh] do
        assert %{state: "available"} = decision(device.uid)
      end

      fresh_version = device_xmin(fresh.uid)

      # Two minutes pass for the self-report; the ledger row crosses its window too.
      Repo.query!(
        """
        UPDATE platform.device_availability_evidence
        SET observed_at = observed_at - interval '2 minutes',
            expires_at = expires_at - interval '2 minutes'
        WHERE device_uid = $1
        """,
        [liveness.uid]
      )

      Repo.query!(
        """
        UPDATE platform.device_agent_availability
        SET checked_at = checked_at - interval '2 minutes'
        WHERE device_uid = $1
        """,
        [probed.uid]
      )

      Repo.query!("""
      UPDATE platform.availability_settings
      SET expiry_watermark = (now() AT TIME ZONE 'utc') - interval '3 minutes'
      """)

      assert ExpiryWorker.run(System.monotonic_time(:millisecond) + 30_000, 0) == 2

      assert %{state: "unknown", rule: "no_evidence", previous: "available"} =
               decision(liveness.uid)

      assert %{state: "unknown", agents: %{"stale" => 1}} = decision(probed.uid)
      assert device_xmin(fresh.uid) == fresh_version
      assert watermark_lag_seconds() < 60
    end
  end

  describe "identity operations" do
    test "a merge moves evidence to the survivor and re-resolves it; an unmerge re-resolves both",
         %{actor: actor} do
      merged_away = create_device!(actor, "192.0.2.140")
      survivor = create_device!(actor, "192.0.2.141")
      now = DateTime.utc_now()

      {:ok, _} =
        Availability.record_evidence([
          wifi(survivor.uid, :down, DateTime.shift(now, minute: -2)),
          wifi(merged_away.uid, :up, now),
          %{
            device_uid: merged_away.uid,
            source_kind: "camera",
            source_instance: "SITE01-nvr",
            state: :up,
            observed_at: now
          }
        ])

      ledger_row!(actor, merged_away, "agent-a", false, minutes_ago(1))
      assert %{state: "unavailable"} = decision(survivor.uid)

      assert :ok =
               MergeEngine.merge_devices(merged_away.uid, survivor.uid,
                 actor: actor,
                 reason: "availability_resolution_test"
               )

      assert evidence_keys(merged_away.uid) == []

      assert evidence_keys(survivor.uid) == [
               {"camera", "SITE01-nvr", "up"},
               {"wifi_map", "SITE01-wlc", "up"}
             ]

      # The ledger reassignment is unchanged: the row moved with its value.
      assert [{"agent-a", false, _checked_at, 1}] = ledger(survivor.uid)

      assert %{state: "available", kind: kind, conflict: false} = decision(survivor.uid)
      assert kind in ["camera", "wifi_map"]

      # An unmerge re-resolves both devices; the restored one kept no evidence.
      assert %{state: "available"} = decision(merged_away.uid)
      assert :ok = MergeEngine.unmerge_device(merged_away.uid, actor: actor)
      assert %{state: "unknown", previous: "available"} = decision(merged_away.uid)
    end
  end

  describe "lock order" do
    # Real concurrent transactions, so the rows commit; the devices are removed after.
    @tag sandbox: :unboxed
    test "a merge holding both devices moves evidence without waiting on an inline evidence write",
         %{actor: actor} do
      parent = self()
      supervisor = start_supervised!(Task.Supervisor)
      merged_away = create_device!(actor, "192.0.2.170")
      survivor = create_device!(actor, "192.0.2.171")

      try do
        stored_at = DateTime.shift(DateTime.utc_now(), minute: -1)
        {:ok, _} = Availability.record_evidence([wifi(merged_away.uid, :up, stored_at)])

        # The merge's own order: both device rows, then their evidence.
        merge =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Repo.transaction(fn ->
              Resolution.lock_devices([merged_away.uid, survivor.uid])
              send(parent, {:locked, self()})

              receive do
                :move -> :ok
              after
                10_000 -> raise "the test did not release the merge"
              end

              started = System.monotonic_time(:millisecond)
              :ok = Availability.move_evidence(merged_away.uid, survivor.uid)
              send(parent, {:moved, System.monotonic_time(:millisecond) - started})
            end)
          end)

        assert_receive {:locked, merge_pid}, 5_000

        writer =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Availability.record_evidence([wifi(merged_away.uid, :down, DateTime.utc_now())])
          end)

        # The evidence write waits on the merged-away device's row, holding nothing else.
        await_lock_wait!(50)
        send(merge_pid, :move)

        assert_receive {:moved, elapsed_ms}, 5_000
        assert elapsed_ms < 500
        assert {:ok, {:ok, _}} = Task.yield(merge, 5_000)
        assert {:ok, {:ok, %{written: 1}}} = Task.yield(writer, 5_000)
        assert evidence_keys(survivor.uid) == [{"wifi_map", "SITE01-wlc", "up"}]
      after
        TestSupport.delete_device_fixtures!([merged_away.uid, survivor.uid])
      end
    end
  end

  # -- fixtures -------------------------------------------------------------------------

  defp enabled_check!(actor) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "SITE01 isolation " <> Ash.UUID.generate(), scope_query: "in:devices"},
        actor: actor
      )
      |> Ash.create()

    # The enable action's readiness checks are not under test; the state is.
    Repo.query!("UPDATE platform.composite_checks SET state = 'enabled' WHERE id = $1", [
      Ecto.UUID.dump!(check.id)
    ])

    %{check | state: :enabled}
  end

  defp vantage_input(agent_id, expected) do
    %CompositeCheckInput{
      kind: :vantage_point,
      config: %{"agent_id" => agent_id},
      expected: expected
    }
  end

  defp append!(uids) do
    Repo.query!(
      "INSERT INTO platform.availability_invalidations (device_uid) SELECT unnest($1::text[])",
      [uids]
    )
  end

  # Polls (100 ms apart, bounded) until a backend waits on a row lock of a device.
  defp await_lock_wait!(0), do: flunk("no backend waited on a device row lock")

  defp await_lock_wait!(attempts) do
    %{rows: [[waiting]]} =
      Repo.query!("""
      SELECT count(*) FROM pg_stat_activity
      WHERE datname = current_database() AND wait_event_type = 'Lock'
        AND query ILIKE '%ocsf_devices%FOR NO KEY UPDATE%'
      """)

    if waiting > 0 do
      :ok
    else
      Process.sleep(100)
      await_lock_wait!(attempts - 1)
    end
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
    %{rows: [[state, decided_by, conflict, agents]]} =
      Repo.query!(
        """
        SELECT availability_state, availability_decided_by, availability_conflict,
               availability_agents
        FROM platform.ocsf_devices WHERE uid = $1
        """,
        [uid]
      )

    decided_by = decided_by || %{}

    %{
      state: state,
      kind: decided_by["source_kind"],
      class: decided_by["authority_class"],
      reporter: decided_by["reporter_agent_id"],
      rule: decided_by["rule"],
      invalid_pin: decided_by["invalid_pin"],
      previous: get_in(decided_by, ["previous", "state"]),
      conflict: conflict,
      agents: agents
    }
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

  defp transition_jobs do
    %{rows: rows} =
      Repo.query!(
        "SELECT args FROM platform.oban_jobs WHERE worker = $1 ORDER BY id",
        [inspect(Transitions)]
      )

    Enum.map(rows, &hd/1)
  end

  defp transitions_only(jobs), do: Enum.flat_map(jobs, &Map.get(&1, "transitions", []))

  defp evidence_keys(uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT source_kind, source_instance, state FROM platform.device_availability_evidence
        WHERE device_uid = $1 ORDER BY source_kind, source_instance
        """,
        [uid]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp watermark_lag_seconds do
    %{rows: [[lag]]} =
      Repo.query!("""
      SELECT extract(epoch FROM (now() AT TIME ZONE 'utc') - expiry_watermark)::int
      FROM platform.availability_settings
      """)

    lag
  end
end
