defmodule ServiceRadar.Inventory.AvailabilityShadowIntegrationTest do
  @moduledoc """
  Stage b of `add-merged-device-availability` against the real schema: in `shadow` the
  resolver writes only `device_availability_shadow`, on change, from the write paths,
  the invalidation log, the expiry job and the entry pass; nothing a legacy reader sees
  changes; and the divergence report counts what would.

  Every fixture is invented (192.0.2.0/24, SITE01-style names, generated ids).
  """

  use ServiceRadar.DataCase, async: false

  import ServiceRadar.TestSupport.AvailabilityFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Availability.DivergenceReport
  alias ServiceRadar.Inventory.Availability.ExpiryWorker
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Inventory.Availability.ResolverWorker
  alias ServiceRadar.Inventory.Availability.ShadowEntryWorker
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
    {:ok, actor: SystemActor.system(:availability_shadow_test)}
  end

  describe "write paths in shadow" do
    test "a controller's up outranks failing sweeps in the shadow only, and steady sweeps rewrite nothing",
         %{actor: actor} do
      set_mode!("shadow")
      device = create_device!(actor, "192.0.2.110")
      {group, agent_id} = sweep_group!(actor)

      assert {:ok, %{written: 1}} =
               Availability.record_evidence([
                 %{
                   device_uid: device.uid,
                   source_kind: "wifi_map",
                   source_instance: "SITE01-wlc",
                   state: :up,
                   observed_at: DateTime.utc_now()
                 }
               ])

      assert %{state: "available", kind: "wifi_map", conflict: false} = shadow(device.uid)

      sweep!(actor, group, agent_id, "192.0.2.110", false, minutes_ago(4))
      sweep!(actor, group, agent_id, "192.0.2.110", false, minutes_ago(3))

      # The legacy writers decide the device's columns exactly as before.
      assert device_state(device.uid) == {false, "unavailable", "legacy_mirror"}

      assert %{
               state: "available",
               kind: "wifi_map",
               class: "managing_controller",
               conflict: true,
               agents: %{"down" => 1, "total" => 1, "up" => 0}
             } = shadow(device.uid)

      version = shadow_xmin(device.uid)

      sweep!(actor, group, agent_id, "192.0.2.110", false, minutes_ago(2))
      sweep!(actor, group, agent_id, "192.0.2.110", false, minutes_ago(1))
      ResolverWorker.pass()

      assert shadow_xmin(device.uid) == version
    end

    test "in legacy, inline resolution issues no query once the mode is cached", %{actor: actor} do
      device = create_device!(actor, "192.0.2.111")

      with_mode_cache(fn ->
        assert Mode.cached() == :legacy

        queries =
          count_queries(fn -> {:ok, :legacy} = Availability.resolve_devices([device.uid]) end)

        assert queries == 0
      end)

      assert shadow(device.uid) == nil
    end
  end

  describe "resolver worker" do
    test "re-resolves validation scans, a pin change and a new negative control without new evidence",
         %{actor: actor} do
      set_mode!("shadow")
      device = create_device!(actor, "192.0.2.120")

      ledger_row!(actor, device, "agent-b", true, minutes_ago(1))
      failing = ledger_row!(actor, device, "agent-a", false, minutes_ago(3))
      update_ledger!(failing, actor, %{is_available: false, checked_at: minutes_ago(2)})
      ledger_before = ledger(device.uid)
      legacy_before = device_state(device.uid)

      drain!()

      assert %{state: "available", agents: %{"up" => 1, "down" => 1}, conflict: false} =
               shadow(device.uid)

      pin!(actor, device, "agent-a")
      drain!()

      assert %{state: "unavailable", reporter: "agent-a", conflict: true} = shadow(device.uid)

      check = enabled_check!(actor)
      control = vantage_input("agent-a", "blocked")
      assert VantageExpectations.materialize(check, [control], [device.uid]) == 1
      drain!()

      assert %{
               state: "available",
               reporter: "agent-b",
               invalid_pin: true,
               agents: %{"blocked_verified" => 1, "total" => 1}
             } = shadow(device.uid)

      # Resolution reads the ledger and the device; it writes neither.
      assert ledger(device.uid) == ledger_before
      assert device_state(device.uid) == legacy_before
    end

    test "a device created or restored outside legacy is appended, whichever path restores it",
         %{actor: actor} do
      legacy = create_device!(actor, "192.0.2.122")
      set_mode!("shadow")
      created = create_device!(actor, "192.0.2.123")

      assert invalidation_uids() == [created.uid]

      # A tombstone and the raw restore any writer may issue.
      for deleted_at <- ["(now() AT TIME ZONE 'utc')", "NULL"] do
        Repo.query!(
          "UPDATE platform.ocsf_devices SET deleted_at = #{deleted_at} WHERE uid = $1",
          [
            legacy.uid
          ]
        )
      end

      assert invalidation_uids() == [created.uid, legacy.uid]
    end

    test "a sweep group's interval change or deletion appends its devices outside legacy only",
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
      assert invalidation_uids() == []

      set_mode!("shadow")
      set_interval.("5m")
      assert invalidation_uids() == []

      set_interval.("2h")
      assert invalidation_uids() == [device.uid]

      Repo.query!("DELETE FROM platform.sweep_groups WHERE id::text = $1", [group.id])
      assert invalidation_uids() == [device.uid, device.uid]
    end

    test "a pass resolves at most 500 devices and re-appends the rest; legacy only consumes",
         %{actor: actor} do
      set_mode!("shadow")
      uids = for n <- 1..501, do: "sr:absent-#{String.pad_leading(Integer.to_string(n), 4, "0")}"
      append!(uids ++ Enum.take(uids, 3))

      assert %{claimed: 504} = ResolverWorker.pass()
      assert invalidation_uids() == [List.last(uids)]

      set_mode!("legacy")
      device = create_device!(actor, "192.0.2.121")
      append!([device.uid, device.uid])

      assert %{claimed: 3, resolved: 0} = ResolverWorker.pass()
      assert invalidation_uids() == []
      assert shadow(device.uid) == nil
    end
  end

  describe "expiry" do
    test "an expired self-report and an aged-out agent result re-resolve; fresh evidence is untouched",
         %{actor: actor} do
      set_mode!("shadow")
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
        assert %{state: "available"} = shadow(device.uid)
      end

      fresh_version = shadow_xmin(fresh.uid)

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
               shadow(liveness.uid)

      assert %{state: "unknown", agents: %{"stale" => 1}} = shadow(probed.uid)
      assert shadow_xmin(fresh.uid) == fresh_version
      assert watermark_lag_seconds() < 60
    end
  end

  describe "identity operations" do
    test "a merge moves evidence to the survivor and re-resolves it; an unmerge re-resolves both",
         %{actor: actor} do
      set_mode!("shadow")
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
      assert %{state: "unavailable"} = shadow(survivor.uid)

      assert :ok =
               MergeEngine.merge_devices(merged_away.uid, survivor.uid,
                 actor: actor,
                 reason: "availability_shadow_test"
               )

      assert evidence_keys(merged_away.uid) == []

      assert evidence_keys(survivor.uid) == [
               {"camera", "SITE01-nvr", "up"},
               {"wifi_map", "SITE01-wlc", "up"}
             ]

      # The ledger reassignment is unchanged: the row moved with its value.
      assert [{"agent-a", false, _checked_at, 1}] = ledger(survivor.uid)

      assert %{state: "available", kind: kind, conflict: false} = shadow(survivor.uid)
      assert kind in ["camera", "wifi_map"]

      # An unmerge re-resolves both devices; the restored one kept no evidence.
      assert %{state: "available"} = shadow(merged_away.uid)
      assert :ok = MergeEngine.unmerge_device(merged_away.uid, actor: actor)
      assert %{state: "unknown", previous: "available"} = shadow(merged_away.uid)
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
        set_mode!("shadow")
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
        set_mode!("legacy")

        Repo.query!(
          "DELETE FROM platform.availability_invalidations WHERE device_uid = ANY($1::text[])",
          [[merged_away.uid, survivor.uid]]
        )

        TestSupport.delete_device_fixtures!([merged_away.uid, survivor.uid])
      end
    end
  end

  describe "entering and leaving shadow" do
    test "entering resolves every device once and seeds the compatibility table; leaving drops the shadow",
         %{actor: actor} do
      probed = create_device!(actor, "192.0.2.150")
      silent = create_device!(actor, "192.0.2.151")
      ledger_row!(actor, probed, "agent-a", true, minutes_ago(1))

      # A device that predates stage a has no compatibility row.
      Repo.query!("DELETE FROM platform.device_availability_legacy WHERE device_uid = $1", [
        silent.uid
      ])

      assert {:ok, %{from: :legacy, to: :shadow}} = Mode.enter_shadow()
      assert {:ok, %{from: :shadow, to: :shadow}} = Mode.enter_shadow()
      assert entry_jobs() == [{"resolve", "scheduled"}, {"seed_legacy", "available"}]

      perform_job(ShadowEntryWorker, %{"phase" => "resolve"})
      assert :ok = perform_job(ShadowEntryWorker, %{"phase" => "seed_legacy"})

      assert %{state: "available"} = shadow(probed.uid)
      assert %{state: "unknown", rule: "no_evidence"} = shadow(silent.uid)
      assert legacy_value(silent.uid) == true
      assert watermark_lag_seconds() < 60

      versions = Enum.map([probed, silent], &shadow_xmin(&1.uid))
      perform_job(ShadowEntryWorker, %{"phase" => "resolve"})
      assert Enum.map([probed, silent], &shadow_xmin(&1.uid)) == versions

      assert {:ok, %{from: :shadow, to: :legacy}} = Mode.enter_legacy()
      assert entry_jobs() == []
      assert shadow(probed.uid) == nil
      assert Mode.current() == :legacy
    end
  end

  describe "divergence report" do
    test "counts what would change, unknowns, controls, invalid pins, Armis pushes and coalesced flips",
         %{actor: actor} do
      set_mode!("shadow")
      source = armis_source!(actor)

      # Pushed available today; an agent's validation scans confirm it unreachable.
      ingest_armis!(actor, source, "192.0.2.160", "armis-160")
      armis_device = device_by_ip("192.0.2.160")
      confirmed_down!(actor, armis_device, "agent-a")

      # No evidence at all, while the column says available.
      silent = create_device!(actor, "192.0.2.161")

      # Pinned to an agent that a check expects to be blocked, which reaches it.
      pinned = create_device!(actor, "192.0.2.162")
      ledger_row!(actor, pinned, "agent-control", true, minutes_ago(1))
      pin!(actor, pinned, "agent-control")
      check = enabled_check!(actor)

      VantageExpectations.materialize(check, [vantage_input("agent-control", "blocked")], [
        pinned.uid
      ])

      # A controller says up, then down inside the coalescing window.
      flipped = create_device!(actor, "192.0.2.163")
      now = DateTime.utc_now()

      {:ok, _} =
        Availability.record_evidence([wifi(flipped.uid, :up, DateTime.shift(now, minute: -1))])

      {:ok, _} = Availability.record_evidence([wifi(flipped.uid, :down, now)])

      Availability.resolve_devices([armis_device.uid, silent.uid, pinned.uid])

      report = DivergenceReport.build(samples: 100)
      devices = report.devices

      assert armis_device.uid in devices.would_change.samples
      assert silent.uid in devices.would_become_unknown.samples
      assert devices.would_become_unknown.holding_is_available_true >= 1
      assert pinned.uid in devices.invalid_pins.samples
      assert pinned.uid in devices.policy_violations.samples

      assert Enum.any?(report.cells, fn cell ->
               armis_device.uid in cell.samples and
                 {cell.legacy_is_available, cell.legacy_badge, cell.shadow_state} ==
                   {true, "offline", "unavailable"} and
                 {cell.source_kind, cell.authority_class} == {"agent_probe", "active_probe"}
             end)

      assert [armis] = Enum.filter(report.armis, &(&1.id == to_string(source.id)))
      assert armis.would_change == 1

      assert [%{legacy_push: "available", merged_push: "unavailable", samples: [armis_uid]}] =
               Enum.filter(armis.by_direction, &(&1.legacy_push != &1.merged_push))

      assert armis_uid == armis_device.uid

      assert [%{source_kind: "wifi_map", samples: flip_samples}] = report.r5.coalesced_flips
      assert flipped.uid in flip_samples

      assert is_binary(DivergenceReport.summary_text(report))
      assert {:ok, _json} = Jason.encode(report)
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

  defp armis_source!(actor) do
    # Integrations need a connected agent to exist.
    agent_uid = "agent-" <> Ash.UUID.generate()

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: agent_uid, name: agent_uid},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{secret_key: "secret", api_key: "api"})
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "SITE01 armis " <> Ash.UUID.generate(),
        source_type: :armis,
        endpoint: "https://armis.example.com/#{System.unique_integer([:positive])}",
        northbound_enabled: true,
        custom_fields: ["availability"]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp ingest_armis!(actor, source, ip, armis_device_id) do
    update = %{
      "ip" => ip,
      "hostname" => "armis-#{armis_device_id}.example.com",
      "source" => "armis",
      "is_available" => true,
      "metadata" => %{
        "armis_device_id" => armis_device_id,
        "integration_id" => armis_device_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{"sync_service_id" => source.id}
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)
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

  defp with_mode_cache(fun) do
    previous = Application.get_env(:serviceradar_core, Mode)
    Application.put_env(:serviceradar_core, Mode, cache_ms: 60_000)
    Mode.reset_cache()

    try do
      fun.()
    after
      Application.put_env(:serviceradar_core, Mode, previous || [])
      Mode.reset_cache()
    end
  end

  defp count_queries(fun) do
    test_pid = self()
    handler = "availability-shadow-query-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:service_radar, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, :repo_query)
      end,
      nil
    )

    try do
      fun.()
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end

  # -- reads ----------------------------------------------------------------------------

  defp shadow(uid) do
    case Repo.query!(
           """
           SELECT availability_state, decided_by, conflict, agents
           FROM platform.device_availability_shadow WHERE device_uid = $1
           """,
           [uid]
         ) do
      %{rows: [[state, decided_by, conflict, agents]]} ->
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

      %{rows: []} ->
        nil
    end
  end

  defp shadow_xmin(uid) do
    %{rows: [[xmin]]} =
      Repo.query!(
        "SELECT xmin::text FROM platform.device_availability_shadow WHERE device_uid = $1",
        [uid]
      )

    xmin
  end

  defp device_by_ip(ip) do
    %{rows: [[uid]]} =
      Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE ip = $1 AND deleted_at IS NULL", [
        ip
      ])

    %{uid: uid}
  end

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

  defp entry_jobs do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT args ->> 'phase', state FROM platform.oban_jobs
        WHERE worker = $1 AND state IN ('available', 'scheduled') ORDER BY 1
        """,
        [inspect(ShadowEntryWorker)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end
end
