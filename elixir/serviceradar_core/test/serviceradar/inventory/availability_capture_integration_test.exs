defmodule ServiceRadar.Inventory.AvailabilityCaptureIntegrationTest do
  @moduledoc """
  Availability capture against the real schema (`add-merged-device-availability`):
  evidence is recorded, the per-agent ledger counter follows every writer, the legacy
  writers keep their value in the compatibility table, and the invalidation log and
  vantage expectations follow the inputs a decision depends on.

  Every fixture is invented (192.0.2.0/24, SITE01-style names, generated ids).
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Availability.ResolverWorker
  alias ServiceRadar.Inventory.Availability.VantageExpectations
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport
  alias ServiceRadar.WifiMap.BatchIngestor

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:availability_capture_test)}
  end

  describe "legacy writers" do
    test "sweeps keep the legacy hysteresis in the compatibility table and the ledger counter",
         %{actor: actor} do
      device = create_device!(actor, "192.0.2.10")
      {group, agent_id} = sweep_group!(actor)

      assert legacy_value(device.uid) == true

      sweep!(actor, group, agent_id, "192.0.2.10", false, minutes_ago(50))
      assert ledger(device.uid, agent_id) == {false, 1}
      assert legacy_value(device.uid) == true

      sweep!(actor, group, agent_id, "192.0.2.10", false, minutes_ago(40))
      assert ledger(device.uid, agent_id) == {false, 2}
      assert legacy_value(device.uid) == false
      assert {false, "unavailable", rule} = device_state(device.uid)
      assert rule != "legacy_mirror"

      sweep!(actor, group, agent_id, "192.0.2.10", false, minutes_ago(30))
      assert ledger(device.uid, agent_id) == {false, 2}

      sweep!(actor, group, agent_id, "192.0.2.10", true, minutes_ago(20))
      assert ledger(device.uid, agent_id) == {true, 0}
      assert legacy_value(device.uid) == true
      assert {true, "available", _rule} = device_state(device.uid)
    end

    test "a sweep result that changes within the same second recounts and a replay does not",
         %{actor: actor} do
      device = create_device!(actor, "192.0.2.11")
      {group, agent_id} = sweep_group!(actor)
      checked_at = minutes_ago(5)

      sweep!(actor, group, agent_id, "192.0.2.11", true, checked_at)
      assert ledger(device.uid, agent_id) == {true, 0}

      sweep!(actor, group, agent_id, "192.0.2.11", false, checked_at)
      assert ledger(device.uid, agent_id) == {false, 1}

      sweep!(actor, group, agent_id, "192.0.2.11", false, checked_at)
      assert ledger(device.uid, agent_id) == {false, 1}

      sweep!(actor, group, agent_id, "192.0.2.11", true, checked_at)
      assert ledger(device.uid, agent_id) == {true, 0}
    end

    test "validation-scan writes reach the threshold and a merge reassignment keeps the count",
         %{actor: actor} do
      device = create_device!(actor, "192.0.2.12")
      survivor = create_device!(actor, "192.0.2.13")
      first = minutes_ago(10)

      {:ok, row} =
        DeviceAgentAvailability
        |> Ash.Changeset.for_create(
          :create,
          %{
            device_uid: device.uid,
            agent_id: "agent-w18",
            is_available: false,
            checked_at: first
          },
          actor: actor
        )
        |> Ash.create()

      assert ledger(device.uid, "agent-w18") == {false, 1}

      row = update_ledger!(row, actor, %{is_available: false, checked_at: minutes_ago(5)})
      assert ledger(device.uid, "agent-w18") == {false, 2}

      # A replay of the same observation is not a new failure.
      row = update_ledger!(row, actor, %{is_available: false, checked_at: row.checked_at})
      assert ledger(device.uid, "agent-w18") == {false, 2}

      {:ok, moved} =
        row
        |> Ash.Changeset.for_update(:reassign_device, %{device_uid: survivor.uid})
        |> Ash.update(actor: actor)

      assert ledger(survivor.uid, "agent-w18") == {false, 2}
      assert moved.checked_at == row.checked_at
    end
  end

  describe "invalidation log" do
    test "a steady sweep appends nothing and real changes append once", %{actor: actor} do
      steady = create_device!(actor, "192.0.2.20")
      renewed = create_device!(actor, "192.0.2.21")
      # A created device is itself an invalidation; consume those first.
      drain!()
      {group, agent_id} = sweep_group!(actor)

      sweep!(actor, group, agent_id, "192.0.2.20", true, minutes_ago(10))
      assert invalidations(steady.uid) == 1
      legacy_version = legacy_xmin(steady.uid)

      # A renewal of a fresh, unchanged result: no log row, no evidence, and the
      # compatibility row is not rewritten.
      sweep!(actor, group, agent_id, "192.0.2.20", true, minutes_ago(5))
      assert invalidations(steady.uid) == 1
      assert legacy_xmin(steady.uid) == legacy_version
      assert evidence(steady.uid) == []

      sweep!(actor, group, agent_id, "192.0.2.20", false, minutes_ago(4))
      assert invalidations(steady.uid) == 2

      # A renewal of a result older than half its freshness window (the group's 1 h
      # interval gives a 125 min window) appends, so the device is re-resolved before
      # the old result would expire.
      sweep!(actor, group, agent_id, "192.0.2.21", true, minutes_ago(90))
      sweep!(actor, group, agent_id, "192.0.2.21", true, minutes_ago(1))
      assert invalidations(renewed.uid) == 2

      pin!(actor, steady, agent_id)
      assert invalidations(steady.uid) == 3
      pin!(actor, steady, agent_id)
      assert invalidations(steady.uid) == 3
    end
  end

  describe "evidence capture" do
    test "a reported Wi-Fi status is evidence, a missing one is not, and capture changes no legacy value",
         %{actor: actor} do
      collected_at = DateTime.truncate(DateTime.utc_now(), :second)

      ingest_wifi!(actor, collected_at, "SITE01-wlc", "wifi_controller", [
        {"SITE01-AP001", "Down"},
        {"SITE01-AP002", nil}
      ])

      ap1 = device_by_hostname("SITE01-AP001")
      ap2 = device_by_hostname("SITE01-AP002")

      # The controller's down decides the first; the second, with no evidence, is unknown.
      assert {false, "unavailable", _} = device_state(ap1)
      {:ok, _} = Availability.resolve_devices([ap2])
      assert {false, "unknown", "no_evidence"} = device_state(ap2)
      assert legacy_value(ap1) == false
      assert legacy_value(ap2) == true

      assert [
               %{
                 source_kind: "wifi_map",
                 source_instance: "SITE01-wlc",
                 authority_class: "managing_controller",
                 state: "down"
               } = stored
             ] = evidence(ap1)

      assert evidence(ap2) == []

      # The same batch again: the record is current, so it is not rewritten.
      ingest_wifi!(actor, collected_at, "SITE01-wlc", "wifi_controller", [
        {"SITE01-AP001", "Down"},
        {"SITE01-AP002", nil}
      ])

      assert [%{xmin: xmin}] = evidence(ap1)
      assert xmin == stored.xmin

      # A seed import declares inventory; it does not report a controller's view.
      ingest_wifi!(actor, collected_at, "SITE02-seed", "wifi_map_seed", [{"SITE02-AP001", "Up"}])

      assert [%{authority_class: "inventory_declared", state: "up"}] =
               evidence(device_by_hostname("SITE02-AP001"))

      without_capture(fn ->
        ingest_wifi!(actor, collected_at, "SITE03-wlc", "wifi_controller", [
          {"SITE03-AP001", "Down"},
          {"SITE03-AP002", nil}
        ])
      end)

      ap3 = device_by_hostname("SITE03-AP001")
      ap4 = device_by_hostname("SITE03-AP002")

      assert evidence(ap3) == []
      assert legacy_value(ap3) == legacy_value(ap1)
      assert legacy_value(ap4) == legacy_value(ap2)
    end

    test "sources keep separate records and a resubmission inside the lease writes nothing",
         %{actor: actor} do
      device = create_device!(actor, "192.0.2.30")
      now = DateTime.utc_now()

      submissions = [
        %{device_uid: device.uid, source_kind: "wifi_map", state: :up, observed_at: now},
        %{device_uid: device.uid, source_kind: "camera", state: :down, observed_at: now},
        %{device_uid: device.uid, source_kind: "agent_liveness", state: :down, observed_at: now},
        %{device_uid: device.uid, source_kind: "netbox", state: :up, observed_at: now},
        %{device_uid: "sr:absent", source_kind: "camera", state: :up, observed_at: now}
      ]

      assert {:ok, %{written: 2, rejected: rejected}} = Availability.record_evidence(submissions)
      assert rejected == %{up_only_class: 1, unregistered_source: 1}

      stored = Map.new(evidence(device.uid), &{&1.source_kind, &1})
      assert %{"camera" => %{state: "down"}, "wifi_map" => %{state: "up"}} = stored

      later = DateTime.shift(now, minute: 1)
      resubmitted = Enum.map(submissions, &%{&1 | observed_at: later})
      assert {:ok, %{written: 0}} = Availability.record_evidence(resubmitted)

      assert Map.new(evidence(device.uid), &{&1.source_kind, &1.xmin}) ==
               Map.new(stored, fn {kind, row} -> {kind, row.xmin} end)
    end
  end

  describe "vantage expectations" do
    test "follow the enabled check's inputs and scope, and leave with a disabled check",
         %{actor: actor} do
      d1 = create_device!(actor, "192.0.2.40")
      d2 = create_device!(actor, "192.0.2.41")
      drain!()
      check = enabled_check!(actor)

      witness = vantage_input("agent-witness", "available")
      control = vantage_input("agent-control", "blocked")

      assert VantageExpectations.materialize(check, [witness, control], [d1.uid, d2.uid]) == 4

      assert expectations(check) ==
               Enum.sort([
                 {d1.uid, "agent-control", "blocked"},
                 {d1.uid, "agent-witness", "reachable"},
                 {d2.uid, "agent-control", "blocked"},
                 {d2.uid, "agent-witness", "reachable"}
               ])

      assert VantageExpectations.materialize(check, [witness, control], [d1.uid, d2.uid]) == 0
      assert invalidations(d1.uid) == 2

      # The witness input is gone: its rows go, and each device is invalidated once more.
      assert VantageExpectations.materialize(check, [control], [d1.uid, d2.uid]) == 2
      assert invalidations(d1.uid) == 3

      # Only d1 still has a verdict, so d2 has left the scope.
      verdict!(actor, check, d1.uid)
      assert VantageExpectations.prune(check) == 1
      assert expectations(check) == [{d1.uid, "agent-control", "blocked"}]

      {:ok, _} =
        check
        |> Ash.Changeset.for_update(:set_state, %{state: :disabled})
        |> Ash.update(actor: actor)

      assert expectations(check) == []
    end
  end

  # -- fixtures -------------------------------------------------------------------------

  defp create_device!(actor, ip) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          ip: ip,
          hostname: "host-" <> String.replace(ip, ".", "-") <> ".example.com",
          discovery_sources: ["netbox"],
          tags: %{}
        },
        actor: actor
      )
      |> Ash.create()

    device
  end

  defp sweep_group!(actor) do
    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "SITE01 sweep " <> Ash.UUID.generate(), partition: "default", agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    {group, "agent-" <> Ash.UUID.generate()}
  end

  defp sweep!(actor, group, agent_id, ip, available?, checked_at) do
    result = %{
      "host_ip" => ip,
      "available" => available?,
      "port_results" => [],
      "last_sweep_time" => DateTime.to_iso8601(checked_at)
    }

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results([result], Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: "default"
             )
  end

  defp update_ledger!(row, actor, attrs) do
    {:ok, row} =
      row
      |> Ash.Changeset.for_update(:update, attrs, actor: actor)
      |> Ash.update()

    row
  end

  defp pin!(actor, device, agent_id) do
    {:ok, _} =
      device
      |> Ash.Changeset.for_update(:update, %{availability_source_agent_id: agent_id},
        actor: actor
      )
      |> Ash.update()
  end

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

  defp verdict!(actor, check, device_uid) do
    now = DateTime.utc_now()

    {:ok, _} =
      DeviceCompositeCheckResult
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: device_uid,
          check_id: check.id,
          verdict: "isolated_verified",
          status: :healthy,
          inputs: %{},
          evaluated_at: now,
          changed_at: now
        },
        actor: actor
      )
      |> Ash.create()
  end

  defp ingest_wifi!(actor, collected_at, source_name, source_kind, access_points) do
    payload = %{
      "schema" => "serviceradar.wifi_map.batch.v1",
      "collection_timestamp" => DateTime.to_iso8601(collected_at),
      "source" => %{"name" => source_name, "source_kind" => source_kind},
      "access_points" =>
        Enum.map(access_points, fn {name, status} ->
          then(
            %{"site_code" => String.slice(name, 0, 6), "name" => name, "serial" => "SN-" <> name},
            &if(status, do: Map.put(&1, "status", status), else: &1)
          )
        end)
    }

    assert :ok = BatchIngestor.ingest(payload, %{partition: "default"}, actor: actor)
  end

  defp without_capture(fun) do
    previous = Application.get_env(:serviceradar_core, Availability)
    Application.put_env(:serviceradar_core, Availability, evidence_capture: false)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:serviceradar_core, Availability, previous),
        else: Application.delete_env(:serviceradar_core, Availability)
    end
  end

  defp drain! do
    if ResolverWorker.pass().claimed > 0, do: drain!(), else: :ok
  end

  defp minutes_ago(minutes) do
    DateTime.utc_now() |> DateTime.shift(minute: -minutes) |> DateTime.truncate(:microsecond)
  end

  # -- reads ----------------------------------------------------------------------------

  defp device_state(uid) do
    %{rows: [[available, state, rule]]} =
      Repo.query!(
        """
        SELECT is_available, availability_state, availability_decided_by ->> 'rule'
        FROM platform.ocsf_devices WHERE uid = $1
        """,
        [uid]
      )

    {available, state, rule}
  end

  defp device_by_hostname(hostname) do
    %{rows: [[uid]]} =
      Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE hostname = $1", [hostname])

    uid
  end

  defp ledger(uid, agent_id) do
    %{rows: [[available, count]]} =
      Repo.query!(
        """
        SELECT is_available, consecutive_down FROM platform.device_agent_availability
        WHERE device_uid = $1 AND agent_id = $2
        """,
        [uid, agent_id]
      )

    {available, count}
  end

  defp legacy_value(uid) do
    %{rows: [[available]]} =
      Repo.query!(
        "SELECT is_available FROM platform.device_availability_legacy WHERE device_uid = $1",
        [uid]
      )

    available
  end

  defp legacy_xmin(uid) do
    %{rows: [[xmin]]} =
      Repo.query!(
        "SELECT xmin::text FROM platform.device_availability_legacy WHERE device_uid = $1",
        [uid]
      )

    xmin
  end

  defp invalidations(uid) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.availability_invalidations WHERE device_uid = $1",
        [uid]
      )

    count
  end

  defp evidence(uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT source_kind, source_instance, authority_class, state, xmin::text
        FROM platform.device_availability_evidence
        WHERE device_uid = $1 ORDER BY source_kind, source_instance
        """,
        [uid]
      )

    Enum.map(rows, fn [kind, instance, class, state, xmin] ->
      %{
        source_kind: kind,
        source_instance: instance,
        authority_class: class,
        state: state,
        xmin: xmin
      }
    end)
  end

  defp expectations(check) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT device_uid, agent_id, expectation FROM platform.device_vantage_expectations
        WHERE check_id = $1
        """,
        [Ecto.UUID.dump!(check.id)]
      )

    rows |> Enum.map(&List.to_tuple/1) |> Enum.sort()
  end
end
