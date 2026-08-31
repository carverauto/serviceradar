defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDataTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData

  setup do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{
      actor: SystemActor.system(:mtr_data_test),
      scope: Scope.for_user(user)
    }
  end

  test "list_pending_jobs excludes expired active mtr commands", %{actor: actor, scope: scope} do
    stale =
      create_mtr_command(actor, "agent-stale", "192.0.2.10",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        status: :acknowledged
      )

    fresh =
      create_mtr_command(actor, "agent-fresh", "192.0.2.20",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        status: :sent
      )

    assert {:ok, jobs} = MtrData.list_pending_jobs(scope)

    job_ids = MapSet.new(Enum.map(jobs, & &1.id))

    assert MapSet.member?(job_ids, fresh.id)
    refute MapSet.member?(job_ids, stale.id)
  end

  test "list_bulk_jobs matches targets from bulk payloads", %{actor: actor, scope: scope} do
    unrelated =
      create_bulk_mtr_command(actor, "agent-other", ["203.0.113.10", "router-other"],
        inserted_at: DateTime.add(DateTime.utc_now(), -30, :second)
      )

    matching =
      create_bulk_mtr_command(actor, "agent-bulk", ["192.0.2.10", "core-sw01"],
        inserted_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:ok, jobs} = MtrData.list_bulk_jobs(scope, target_filter: "core-sw01")

    assert Enum.map(jobs, & &1.id) == [matching.id]
    refute Enum.any?(jobs, &(&1.id == unrelated.id))
  end

  test "list_bulk_jobs excludes expired active bulk commands", %{actor: actor, scope: scope} do
    stale =
      create_bulk_mtr_command(actor, "agent-stale", ["192.0.2.10"],
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        status: :queued
      )

    recent =
      create_bulk_mtr_command(actor, "agent-recent", ["192.0.2.20"],
        inserted_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:ok, jobs} = MtrData.list_bulk_jobs(scope)

    job_ids = MapSet.new(Enum.map(jobs, & &1.id))

    refute MapSet.member?(job_ids, stale.id)
    assert MapSet.member?(job_ids, recent.id)
  end

  test "list_traces_paginated applies relative MTR time filters" do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    old_time = DateTime.add(now, -2, :day)

    old_id = insert_mtr_trace!("agent-time", "198.51.100.10", old_time)
    fresh_id = insert_mtr_trace!("agent-time", "198.51.100.20", now)

    assert {:ok, %{rows: rows, total_count: 1}} =
             MtrData.list_traces_paginated(srql_query: "in:mtr_traces time:last_1h", limit: 50)

    ids = Enum.map(rows, & &1["id"])
    assert fresh_id in ids
    refute old_id in ids
  end

  test "list_traces_paginated applies absolute MTR time ranges" do
    inside_time = ~U[2026-05-07 10:00:00Z]
    outside_time = ~U[2026-05-09 10:00:00Z]

    inside_id = insert_mtr_trace!("agent-absolute", "203.0.113.10", inside_time)
    outside_id = insert_mtr_trace!("agent-absolute", "203.0.113.20", outside_time)

    query = "in:mtr_traces time:[2026-05-07T00:00:00Z,2026-05-08T00:00:00Z]"

    assert {:ok, %{rows: rows, total_count: 1}} =
             MtrData.list_traces_paginated(srql_query: query, limit: 50)

    ids = Enum.map(rows, & &1["id"])
    assert inside_id in ids
    refute outside_id in ids
  end

  test "list_traces_paginated uses stable pages for equal timestamps" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    ids =
      for target <- ["192.0.2.101", "192.0.2.102", "192.0.2.103"] do
        insert_mtr_trace!("agent-stable", target, timestamp)
      end

    assert {:ok, %{rows: page_1}} =
             MtrData.list_traces_paginated(
               srql_query: "in:mtr_traces agent_id:agent-stable sort:time:desc",
               limit: 2,
               page: 1
             )

    assert {:ok, %{rows: page_2}} =
             MtrData.list_traces_paginated(
               srql_query: "in:mtr_traces agent_id:agent-stable sort:time:desc",
               limit: 2,
               page: 2
             )

    page_1_ids = MapSet.new(Enum.map(page_1, & &1["id"]))
    page_2_ids = MapSet.new(Enum.map(page_2, & &1["id"]))

    assert MapSet.disjoint?(page_1_ids, page_2_ids)
    assert MapSet.subset?(MapSet.union(page_1_ids, page_2_ids), MapSet.new(ids))
  end

  test "trace_coverage reports retained reachability counts across filters" do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert_mtr_trace!("agent-coverage-a", "coverage.example", now, target_reached: true)

    insert_mtr_trace!("agent-coverage-b", "coverage.example", DateTime.add(now, -60, :second), target_reached: false)

    insert_mtr_trace!("agent-coverage-a", "other.example", now, target_reached: true)

    assert {:ok, coverage} = MtrData.trace_coverage(target_filter: "coverage.example")

    assert coverage.trace_count == 2
    assert coverage.reached_count == 1
    assert coverage.failed_count == 1
    assert coverage.earliest_time
    assert coverage.latest_time
  end

  test "list_traces exposes only reached terminal destination observations and trends" do
    target = "destination-window.example"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    silent_transit_id =
      insert_mtr_trace!("agent-destination", target, DateTime.add(now, -1, :second),
        target_reached: true,
        total_hops: 3,
        hops: [
          {"10.0.0.1", 10_000, 0.0},
          {"*", 0, 100.0, 10, 0},
          {target, 30_000, 0.0, 10, 10}
        ]
      )

    partial_destination_id =
      insert_mtr_trace!("agent-destination", target, now,
        target_reached: true,
        total_hops: 2,
        hops: [
          {"10.0.0.1", 8_000, 0.0},
          {target, 40_000, 12.5, 20, 5}
        ]
      )

    unreached_id =
      insert_mtr_trace!("agent-destination", target, DateTime.add(now, -2, :second),
        target_reached: false,
        total_hops: 3,
        hops: [
          {"10.0.0.1", 11_000, 0.0},
          {"10.0.0.2", 900_000, 0.0},
          {"*", 0, 100.0, 10, 0}
        ]
      )

    for_result =
      for offset <- 3..50 do
        insert_mtr_trace!("agent-destination", target, DateTime.add(now, -offset, :second),
          target_reached: true,
          total_hops: 1,
          hops: [{target, 5_000, 0.0}]
        )
      end

    oldest_id = List.last(for_result)

    assert {:ok, traces} = MtrData.list_traces(target_filter: target)
    assert length(traces) == 50

    trace_by_id = Map.new(traces, &{&1["id"], &1})

    refute Map.has_key?(trace_by_id, oldest_id)

    assert %{
             "destination_sent" => 10,
             "destination_received" => 10,
             "destination_avg_us" => 30_000,
             "destination_loss_pct" => silent_destination_loss_pct
           } = trace_by_id[silent_transit_id]

    assert_in_delta(silent_destination_loss_pct, 0.0, 1.0e-10)

    assert %{
             "destination_sent" => 20,
             "destination_received" => 5,
             "destination_avg_us" => 40_000,
             "destination_loss_pct" => 75.0
           } = trace_by_id[partial_destination_id]

    assert %{
             "destination_sent" => nil,
             "destination_received" => nil,
             "destination_avg_us" => nil,
             "destination_loss_pct" => nil
           } = trace_by_id[unreached_id]

    trends = MtrData.build_trends(traces)
    unreached_time = trace_by_id[unreached_id]["time"]

    assert {trace_by_id[silent_transit_id]["time"], 30_000} in trends.latency
    assert {trace_by_id[partial_destination_id]["time"], 40_000} in trends.latency
    refute Enum.any?(trends.latency, fn {time, _latency} -> time == unreached_time end)
  end

  test "list_traces returns a fixed deterministic window with one latest terminal sample per trace" do
    target = "fixed-device-window.example"
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)
    trace_ids = Enum.map(1..51, &fixture_uuid/1)

    Enum.each(trace_ids, fn trace_id ->
      insert_mtr_trace!("agent-fixed-window", target, timestamp,
        id: trace_id,
        target_reached: true,
        total_hops: 1
      )
    end)

    latest_trace_id = List.last(trace_ids)
    latest_hop_time = DateTime.add(timestamp, 1, :second)

    insert_mtr_hop!(latest_trace_id, timestamp, 1, {target, 90_000, 100.0, 10, 0}, id: fixture_uuid(902))

    insert_mtr_hop!(latest_trace_id, latest_hop_time, 1, {target, 40_000, 80.0, 10, 2}, id: fixture_uuid(900))

    selected_hop_id = fixture_uuid(901)

    insert_mtr_hop!(latest_trace_id, latest_hop_time, 1, {target, 0, 0.0, 7, 7}, id: selected_hop_id)

    assert {:ok, traces} = MtrData.list_traces(target_filter: target, limit: 50)

    expected_ids = trace_ids |> Enum.drop(1) |> Enum.reverse()

    assert ^expected_ids = Enum.map(traces, & &1["id"])
    assert length(traces) == 50
    assert Enum.uniq_by(traces, & &1["id"]) == traces

    assert %{
             "id" => ^latest_trace_id,
             "destination_sent" => 7,
             "destination_received" => 7,
             "destination_avg_us" => 0,
             "destination_loss_pct" => selected_loss_pct
           } = hd(traces)

    assert_in_delta(selected_loss_pct, 0.0, 1.0e-10)
  end

  test "get_trace_detail preserves duplicate hops in deterministic diagnostic order" do
    target = "raw-terminal-duplicates.example"
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    trace_id =
      insert_mtr_trace!("agent-raw-hops", target, timestamp,
        target_reached: true,
        total_hops: 1
      )

    older_hop_id = fixture_uuid(912)
    newer_low_id = fixture_uuid(910)
    newer_high_id = fixture_uuid(911)
    latest_hop_time = DateTime.add(timestamp, 1, :second)

    insert_mtr_hop!(trace_id, timestamp, 1, {target, 90_000, 100.0, 10, 0}, id: older_hop_id)

    insert_mtr_hop!(trace_id, latest_hop_time, 1, {target, 40_000, 80.0, 10, 2}, id: newer_low_id)

    insert_mtr_hop!(trace_id, latest_hop_time, 1, {target, 10_000, 0.0, 10, 10}, id: newer_high_id)

    assert {:ok, %{"id" => ^trace_id}, hops} = MtrData.get_trace_detail(%{}, trace_id)

    assert Enum.map(hops, & &1["id"]) == [newer_high_id, newer_low_id, older_hop_id]
    assert Enum.all?(Enum.take(hops, 2), &(DateTime.compare(&1["time"], latest_hop_time) == :eq))
    assert DateTime.compare(List.last(hops)["time"], timestamp) == :eq
  end

  test "compare_windows handles partial elapsed windows and uneven samples" do
    window_a = %{label: "Today so far", start: ~U[2026-05-07 00:00:00Z], end: ~U[2026-05-07 09:30:00Z]}
    window_b = %{label: "Yesterday same hours", start: ~U[2026-05-06 00:00:00Z], end: ~U[2026-05-06 09:30:00Z]}

    insert_mtr_trace!("agent-window", "192.0.2.10", ~U[2026-05-07 01:00:00Z],
      target_reached: true,
      total_hops: 3,
      hops: [
        {"10.0.0.1", 10_000, 0.0},
        {"10.0.0.2", 20_000, 0.0},
        {"192.0.2.10", 30_000, 0.0}
      ]
    )

    insert_mtr_trace!("agent-window", "192.0.2.10", ~U[2026-05-07 02:00:00Z],
      target_reached: false,
      total_hops: 4,
      hops: [
        {"10.0.0.1", 12_000, 0.0},
        {"10.0.0.3", 28_000, 10.0},
        {"*", 0, 100.0},
        {nil, 0, 100.0}
      ]
    )

    insert_mtr_trace!("agent-window", "192.0.2.10", ~U[2026-05-06 01:00:00Z],
      target_reached: true,
      total_hops: 3,
      hops: [
        {"10.0.0.1", 8_000, 0.0},
        {"10.0.0.2", 16_000, 0.0},
        {"192.0.2.10", 24_000, 0.0}
      ]
    )

    assert {:ok, comparison} =
             MtrData.compare_windows(
               window_a: window_a,
               window_b: window_b,
               target_filter: "192.0.2.10",
               bucket_count: 24
             )

    assert comparison.elapsed_aligned?
    assert comparison.a.trace_count == 2
    assert comparison.b.trace_count == 1
    assert comparison.a.success_rate == 50.0
    assert comparison.b.success_rate == 100.0
    assert comparison.deltas.success_rate == -50.0
    assert length(comparison.a.timeline) == 24
    assert length(comparison.b.timeline) == 24
    assert Enum.any?(comparison.a.timeline, &(&1["trace_count"] == 0))
  end

  test "compare_windows weights destination metrics by destination probes and replies" do
    window_a = %{label: "Current", start: ~U[2026-05-07 00:00:00Z], end: ~U[2026-05-07 06:00:00Z]}
    window_b = %{label: "Baseline", start: ~U[2026-05-06 00:00:00Z], end: ~U[2026-05-06 06:00:00Z]}
    target = "198.51.100.99"

    insert_mtr_trace!("agent-weighted", target, ~U[2026-05-07 01:00:00Z],
      target_reached: true,
      total_hops: 2,
      hops: [
        {"10.0.0.1", 10_000, 0.0},
        {target, 10_000, 0.0, 10, 10}
      ]
    )

    insert_mtr_trace!("agent-weighted", target, ~U[2026-05-07 02:00:00Z],
      target_reached: true,
      total_hops: 2,
      hops: [
        {"10.0.0.2", 20_000, 0.0},
        {target, 90_000, 50.0, 90, 45}
      ]
    )

    insert_mtr_trace!("agent-weighted", target, ~U[2026-05-07 03:00:00Z],
      target_reached: false,
      total_hops: 2,
      hops: [
        {"10.0.0.3", 999_000, 0.0},
        {"10.0.0.4", 999_000, 0.0}
      ]
    )

    insert_mtr_trace!("agent-weighted", target, ~U[2026-05-06 01:00:00Z],
      target_reached: true,
      total_hops: 1,
      hops: [{target, 20_000, 0.0, 10, 10}]
    )

    assert {:ok, comparison} =
             MtrData.compare_windows(
               window_a: window_a,
               window_b: window_b,
               target_filter: target
             )

    assert comparison.a.trace_count == 3
    assert comparison.a.reached_count == 2
    assert comparison.a.failed_count == 1
    assert comparison.a.endpoint_sample_count == 2
    assert comparison.a.avg_destination_us == 75_454.5
    assert comparison.a.destination_loss_pct == 45.0
    assert comparison.deltas.avg_destination_us == 55_454.5
    assert comparison.deltas.destination_loss_pct == 45.0
  end

  test "compare_windows leaves destination metrics and deltas unavailable without terminal observations" do
    window_a = %{label: "Current", start: ~U[2026-05-07 00:00:00Z], end: ~U[2026-05-07 06:00:00Z]}
    window_b = %{label: "Baseline", start: ~U[2026-05-06 00:00:00Z], end: ~U[2026-05-06 06:00:00Z]}
    target = "198.51.100.100"

    insert_mtr_trace!("agent-empty-endpoint", target, ~U[2026-05-07 01:00:00Z],
      target_reached: false,
      total_hops: 2,
      hops: [{"10.0.0.1", 900_000, 0.0}, {"10.0.0.2", 900_000, 0.0}]
    )

    insert_mtr_trace!("agent-empty-endpoint", target, ~U[2026-05-06 01:00:00Z],
      target_reached: true,
      total_hops: 1,
      hops: [{target, 10_000, 0.0, 10, 10}]
    )

    assert {:ok, comparison} =
             MtrData.compare_windows(
               window_a: window_a,
               window_b: window_b,
               target_filter: target
             )

    assert comparison.a.trace_count == 1
    assert comparison.a.reached_count == 0
    assert comparison.a.failed_count == 1
    assert comparison.a.endpoint_sample_count == 0
    assert comparison.a.avg_destination_us == nil
    assert comparison.a.destination_loss_pct == nil
    assert comparison.deltas.avg_destination_us == nil
    assert comparison.deltas.destination_loss_pct == nil
  end

  test "compare_windows reports dominant route signatures and per-agent deltas" do
    window_a = %{label: "Current", start: ~U[2026-05-07 00:00:00Z], end: ~U[2026-05-07 06:00:00Z]}
    window_b = %{label: "Baseline", start: ~U[2026-05-06 00:00:00Z], end: ~U[2026-05-06 06:00:00Z]}

    insert_mtr_trace!("agent-a", "203.0.113.10", ~U[2026-05-07 01:00:00Z],
      hops: [{"10.1.0.1", 10_000, 0.0}, {"10.1.0.2", 20_000, 0.0}, {"203.0.113.10", 30_000, 0.0}]
    )

    insert_mtr_trace!("agent-a", "203.0.113.10", ~U[2026-05-07 02:00:00Z],
      hops: [{"10.1.0.1", 11_000, 0.0}, {"10.1.0.2", 21_000, 0.0}, {"203.0.113.10", 31_000, 0.0}]
    )

    insert_mtr_trace!("agent-a", "203.0.113.10", ~U[2026-05-06 01:00:00Z],
      hops: [{"10.1.0.1", 9_000, 0.0}, {"10.1.0.9", 18_000, 0.0}, {"203.0.113.10", 27_000, 0.0}]
    )

    assert {:ok, comparison} =
             MtrData.compare_windows(
               window_a: window_a,
               window_b: window_b,
               target_filter: "203.0.113.10",
               signature_limit: 3
             )

    [dominant_a | _] = comparison.a.route_signatures
    [dominant_b | _] = comparison.b.route_signatures

    assert dominant_a["trace_count"] == 2
    assert dominant_a["path_preview"] == "10.1.0.1 -> 10.1.0.2 -> 203.0.113.10"
    assert dominant_b["path_preview"] == "10.1.0.1 -> 10.1.0.9 -> 203.0.113.10"
    assert is_binary(dominant_a["representative_trace_id"])

    assert [
             %{
               "agent_id" => "agent-a",
               "a_trace_count" => 2,
               "b_trace_count" => 1,
               "a_success_rate" => 100.0,
               "b_success_rate" => 100.0
             }
           ] = comparison.agents
  end

  defp create_mtr_command(actor, agent_id, target, opts) do
    expires_at = Keyword.fetch!(opts, :expires_at)
    status = Keyword.get(opts, :status, :queued)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"target" => target},
          ttl_seconds: 60,
          expires_at: expires_at
        },
        actor: actor
      )

    case status do
      :queued ->
        command

      :sent ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        command

      :acknowledged ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
        command
    end
  end

  defp create_bulk_mtr_command(actor, agent_id, targets, opts) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(inserted_at, 300, :second))
    status = Keyword.get(opts, :status, :completed)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.bulk_run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"targets" => targets, "protocol" => "icmp"},
          ttl_seconds: 300,
          expires_at: expires_at
        },
        actor: actor
      )

    command =
      case status do
        :queued ->
          command

        :sent ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          command

        :acknowledged ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
          command

        :running ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          {:ok, command} = AgentCommand.start(command, [message: "running"], actor: actor)
          command

        :completed ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          {:ok, command} =
            AgentCommand.complete(
              command,
              [message: "done", result_payload: %{"total_targets" => 2}],
              actor: actor
            )

          command
      end

    completed_at =
      case status do
        :completed -> DateTime.add(inserted_at, 10, :second)
        _ -> nil
      end

    ServiceRadar.Repo.query!(
      "UPDATE platform.agent_commands SET inserted_at = $2, completed_at = $3, expires_at = $4 WHERE command_id = $1",
      [dump_uuid!(command.id), inserted_at, completed_at, expires_at]
    )

    %{command | inserted_at: inserted_at, completed_at: completed_at, expires_at: expires_at}
  end

  defp insert_mtr_trace!(agent_id, target_ip, timestamp, opts \\ []) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    db_id = dump_uuid!(id)
    target_reached = Keyword.get(opts, :target_reached, true)
    total_hops = Keyword.get(opts, :total_hops, opts |> Keyword.get(:hops, []) |> length())
    protocol = Keyword.get(opts, :protocol, "icmp")

    ServiceRadar.Repo.insert_all("mtr_traces", [
      %{
        id: db_id,
        time: timestamp,
        agent_id: agent_id,
        gateway_id: "gateway-test",
        check_id: "check-#{id}",
        check_name: "MTR #{target_ip}",
        device_id: nil,
        target: target_ip,
        target_ip: target_ip,
        target_reached: target_reached,
        total_hops: total_hops,
        protocol: protocol,
        ip_version: 4,
        packet_size: 64,
        partition: "default",
        error: nil,
        created_at: timestamp
      }
    ])

    insert_mtr_hops!(id, timestamp, Keyword.get(opts, :hops, []))

    id
  end

  defp insert_mtr_hops!(_trace_id, _timestamp, []), do: :ok

  defp insert_mtr_hops!(trace_id, timestamp, hops) do
    trace_db_id = dump_uuid!(trace_id)

    rows =
      hops
      |> Enum.with_index(1)
      |> Enum.map(fn {hop, hop_number} ->
        {addr, avg_us, loss_pct, sent, received} = normalize_hop(hop)

        %{
          id: dump_uuid!(Ecto.UUID.generate()),
          time: timestamp,
          trace_id: trace_db_id,
          hop_number: hop_number,
          addr: normalize_hop_addr(addr),
          hostname: nil,
          ecmp_addrs: [],
          asn: nil,
          asn_org: nil,
          mpls_labels: %{},
          sent: sent,
          received: received,
          loss_pct: loss_pct,
          last_us: avg_us,
          avg_us: avg_us,
          min_us: avg_us,
          max_us: avg_us,
          stddev_us: 0,
          jitter_us: 0,
          jitter_worst_us: 0,
          jitter_interarrival_us: 0,
          created_at: timestamp
        }
      end)

    ServiceRadar.Repo.insert_all("mtr_hops", rows)
    :ok
  end

  defp insert_mtr_hop!(trace_id, timestamp, hop_number, hop, opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    {addr, avg_us, loss_pct, sent, received} = normalize_hop(hop)

    ServiceRadar.Repo.insert_all("mtr_hops", [
      %{
        id: dump_uuid!(id),
        time: timestamp,
        trace_id: dump_uuid!(trace_id),
        hop_number: hop_number,
        addr: normalize_hop_addr(addr),
        hostname: nil,
        ecmp_addrs: [],
        asn: nil,
        asn_org: nil,
        mpls_labels: %{},
        sent: sent,
        received: received,
        loss_pct: loss_pct,
        last_us: avg_us,
        avg_us: avg_us,
        min_us: avg_us,
        max_us: avg_us,
        stddev_us: 0,
        jitter_us: 0,
        jitter_worst_us: 0,
        jitter_interarrival_us: 0,
        created_at: timestamp
      }
    ])

    id
  end

  defp normalize_hop_addr("*"), do: nil
  defp normalize_hop_addr(addr), do: addr

  defp normalize_hop({addr, avg_us, loss_pct}) do
    {addr, avg_us, loss_pct, 10, if(loss_pct >= 100.0, do: 0, else: 10)}
  end

  defp normalize_hop({addr, avg_us, loss_pct, sent, received}) do
    {addr, avg_us, loss_pct, sent, received}
  end

  defp fixture_uuid(sequence) do
    suffix = sequence |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "00000000-0000-0000-0000-#{suffix}"
  end

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> uuid
    end
  end
end
