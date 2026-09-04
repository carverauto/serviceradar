defmodule ServiceRadar.AdmissionLaneTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.FlowLeaseSupervisor
  alias ServiceRadar.Admission.FlowSupervisor
  alias ServiceRadar.Admission.FlowTaskSupervisor
  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Admission.RetainedPluginLeaseSupervisor
  alias ServiceRadar.Admission.RetainedPluginSupervisor
  alias ServiceRadar.Admission.RetainedPluginTaskSupervisor
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Cluster.CoordinatorChildren

  test "count, byte, per-agent, and source limits return distinct reasons" do
    parent = self()
    processor = held_processor(parent)
    state_capture = capture_lane_state()

    count_lane = start_lane(processor, max_items: 2, max_items_per_agent: 2)
    first = admit(count_lane, status("agent-a", "one"))
    assert_receive {:started, "one", first_release}
    second = admit(count_lane, status("agent-a", "two"))

    assert {:error, :count_full} =
             Lane.admit(count_lane, status("agent-b", "three"), {self(), make_ref()})

    send(first_release, :release)
    assert_receive {^first, :ok}
    assert_receive {:started, "two", second_release}
    send(second_release, :release)
    assert_receive {^second, :ok}
    assert_empty(count_lane)
    assert_occupied_then_empty(state_capture)

    per_agent_lane = start_lane(processor, max_items: 3, max_items_per_agent: 1)
    admitted = admit(per_agent_lane, status("agent-a", "agent-one"))
    assert_receive {:started, "agent-one", agent_release}

    assert {:error, :per_agent_full} =
             Lane.admit(per_agent_lane, status("agent-a", "agent-two"), {self(), make_ref()})

    send(agent_release, :release)
    assert_receive {^admitted, :ok}
    assert_empty(per_agent_lane)

    byte_lane = start_lane(processor, max_bytes: 265)
    byte_ref = admit(byte_lane, status("agent-a", "12345"))
    assert_receive {:started, "12345", byte_release}

    assert {:error, :configured_byte_full} =
             Lane.admit(byte_lane, status("agent-b", "1"), {self(), make_ref()})

    send(byte_release, :release)
    assert_receive {^byte_ref, :ok}
    assert_empty(byte_lane)

    source_lane = start_lane(fn _ -> :ok end, source_max_bytes: 4)

    assert {:error, :wire_payload_too_large} =
             Lane.admit(source_lane, status("agent-a", "12345"), {self(), make_ref()})
  end

  test "saturation accounting is independent between runtime lanes" do
    parent = self()
    flow_lane = start_lane(held_processor(parent), max_items: 1)
    plugin_lane = start_lane(fn _ -> :ok end, max_items: 1)

    flow_ref = admit(flow_lane, status("agent-a", "held-flow"))
    assert_receive {:started, "held-flow", flow_release}

    assert {:error, :count_full} =
             Lane.admit(flow_lane, status("agent-b", "more-flow"), {self(), make_ref()})

    plugin_ref = admit(plugin_lane, status("agent-a", "plugin"))
    assert_receive {^plugin_ref, :ok}

    send(flow_release, :release)
    assert_receive {^flow_ref, :ok}
    assert_empty(flow_lane)
    assert_empty(plugin_lane)
  end

  test "queued work is FIFO and expires before it starts" do
    parent = self()

    lane =
      start_lane(held_processor(parent),
        queue_wait_ms: 40,
        worker_timeout_ms: 500,
        gateway_call_timeout_ms: 3_540
      )

    first = admit(lane, status("agent-a", "first"))
    assert_receive {:started, "first", release}
    second = admit(lane, status("agent-b", "second"))

    assert_receive {^second, {:error, :admission_timeout}}, 250
    refute_receive {:started, "second", _release}

    send(release, :release)
    assert_receive {^first, :ok}
    assert_empty(lane)
  end

  test "accepted work starts in deterministic FIFO order" do
    parent = self()

    lane =
      start_lane(held_processor(parent),
        queue_wait_ms: 1_000,
        worker_timeout_ms: 1_000,
        gateway_call_timeout_ms: 5_000
      )

    first = admit(lane, status("agent-a", "first"))
    assert_receive {:started, "first", first_release}
    second = admit(lane, status("agent-b", "second"))
    third = admit(lane, status("agent-c", "third"))

    send(first_release, :release)
    assert_receive {^first, :ok}
    assert_receive {:started, "second", second_release}
    send(second_release, :release)
    assert_receive {^second, :ok}
    assert_receive {:started, "third", third_release}
    send(third_release, :release)
    assert_receive {^third, :ok}
  end

  test "worker runtime is bounded and late completion cannot reply twice" do
    state_capture = capture_lane_state()

    lane =
      start_lane(
        fn _status ->
          Process.sleep(200)
          :ok
        end,
        worker_timeout_ms: 30
      )

    reply_ref = admit(lane, status("agent-a", "slow"))

    assert_receive {^reply_ref, {:error, :execution_timeout}}, 250
    refute_receive {^reply_ref, _late_result}, 250
    assert_empty(lane)
    assert_occupied_then_empty(state_capture)
  end

  test "execution timeout does not start replacement work before the worker terminates" do
    parent = self()

    lane =
      start_lane(delayed_link_exit_processor(parent, 150),
        max_items: 2,
        queue_wait_ms: 500,
        worker_timeout_ms: 50,
        gateway_call_timeout_ms: 3_550
      )

    first_ref = admit(lane, status("agent-a", "first"))
    assert_receive {:started, "first", first_worker}
    first_monitor = Process.monitor(first_worker)

    second_ref = admit(lane, status("agent-b", "second"))
    assert_receive {^first_ref, {:error, :execution_timeout}}, 250

    receive do
      {:DOWN, ^first_monitor, :process, ^first_worker, _reason} ->
        :ok

      {:started, "second", second_worker} ->
        Process.exit(second_worker, :kill)
        flunk("replacement started while the timed-out worker was still alive")
    after
      300 ->
        flunk("timed-out worker did not terminate")
    end

    assert_receive {:started, "second", second_worker}
    send(second_worker, :release)
    assert_receive {^second_ref, :ok}
    assert_empty(lane)
  end

  test "caller exit does not start replacement work before the worker terminates" do
    parent = self()

    lane =
      start_lane(delayed_link_exit_processor(parent, 150),
        max_items: 2,
        queue_wait_ms: 500,
        worker_timeout_ms: 1_000,
        gateway_call_timeout_ms: 4_500
      )

    caller =
      spawn(fn ->
        reply_ref = make_ref()

        send(
          parent,
          {:caller_admission, Lane.admit(lane, status("agent-a", "first"), {self(), reply_ref})}
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:caller_admission, :ok}
    assert_receive {:started, "first", first_worker}
    first_monitor = Process.monitor(first_worker)
    second_ref = admit(lane, status("agent-b", "second"))

    Process.exit(caller, :kill)

    receive do
      {:DOWN, ^first_monitor, :process, ^first_worker, _reason} ->
        :ok

      {:started, "second", second_worker} ->
        Process.exit(second_worker, :kill)
        flunk("replacement started while the abandoned worker was still alive")
    after
      300 ->
        flunk("abandoned worker did not terminate")
    end

    assert_receive {:started, "second", second_worker}
    send(second_worker, :release)
    assert_receive {^second_ref, :ok}
    assert_empty(lane)
  end

  test "a crashing worker releases capacity and returns worker_crash" do
    state_capture = capture_lane_state()
    lane = start_lane(fn _status -> exit(:forced_crash) end, max_items: 1)
    reply_ref = admit(lane, status("agent-a", "crash"))

    assert_receive {^reply_ref, {:error, :worker_crash}}, 250

    next_ref = admit(lane, status("agent-b", "also-crash"))
    assert_receive {^next_ref, {:error, :worker_crash}}, 250
    assert_empty(lane)
    assert_occupied_then_empty(state_capture)
  end

  test "fast workers repeatedly complete after their running state is registered" do
    lane = start_lane(fn _status -> :ok end, max_items: 1)

    for iteration <- 1..100 do
      reply_ref = admit(lane, status("agent-a", "fast-#{iteration}"))
      assert_receive {^reply_ref, :ok}
      assert_empty(lane)
    end
  end

  test "lease death after an accepted worker result falls back to the original caller" do
    parent = self()
    lane = start_lane(held_processor(parent), max_items: 1)
    reply_ref = admit(lane, status("agent-a", "committed"))
    assert_receive {:started, "committed", worker}

    [%{lease: lease}] = lane |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()
    true = :erlang.suspend_process(lease)
    send(worker, :release)

    assert_eventually(fn ->
      case lane |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values() do
        [] -> true
        [%{phase: :delivering}] -> true
        _jobs -> false
      end
    end)

    Process.exit(lease, :kill)

    assert_receive {^reply_ref, :ok}, 250
    assert_empty(lane)
  end

  test "lease death after a worker crash falls back to the original caller" do
    parent = self()

    lane =
      start_lane(fn status ->
        send(parent, {:started, status.message, self()})

        receive do
          :crash -> exit(:synthetic_worker_crash)
        end
      end)

    reply_ref = admit(lane, status("agent-a", "crashing"))
    assert_receive {:started, "crashing", worker}

    [%{lease: lease}] = lane |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()
    true = :erlang.suspend_process(lease)
    send(worker, :crash)

    assert_eventually(fn ->
      case lane |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values() do
        [] -> true
        [%{phase: :delivering}] -> true
        _jobs -> false
      end
    end)

    Process.exit(lease, :kill)

    assert_receive {^reply_ref, {:error, :worker_crash}}, 250
    assert_empty(lane)
  end

  test "caller exit releases queued or in-flight capacity" do
    parent = self()
    lane = start_lane(held_processor(parent), max_items: 1)

    caller =
      spawn(fn ->
        reply_ref = make_ref()

        send(
          parent,
          {:caller_admission,
           Lane.admit(lane, status("agent-a", "abandoned"), {self(), reply_ref})}
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:caller_admission, :ok}
    assert_receive {:started, "abandoned", _release}
    Process.exit(caller, :kill)

    assert_eventually(fn ->
      Lane.admit(lane, status("agent-b", "replacement"), {self(), make_ref()}) == :ok
    end)

    assert_receive {:started, "replacement", replacement_release}
    send(replacement_release, :release)
    assert_empty(lane)
  end

  test "coordinator restart gives every accepted caller a terminal reply" do
    parent = self()
    lane = start_lane(held_processor(parent))
    reply_ref = admit(lane, status("agent-a", "restart"))
    assert_receive {:started, "restart", _release}

    Process.exit(lane, :kill)

    assert_receive {^reply_ref, {:error, :coordinator_restart}}, 500
  end

  test "state telemetry reports occupancy before returning to zero after success" do
    state_capture = capture_lane_state()
    lane = start_lane(fn _ -> :ok end)
    reply_ref = admit(lane, status("agent-a", "telemetry"))
    assert_receive {^reply_ref, :ok}
    assert_empty(lane)
    assert_occupied_then_empty(state_capture)
  end

  test "cast admission reports an unavailable flow lane and emits rejection telemetry" do
    parent = self()
    handler_id = {__MODULE__, make_ref()}
    previous = Application.get_env(:serviceradar_core, ServiceRadar.StatusHandler)
    original = previous || []
    missing_lane = unique_name(:missing_flow_lane)

    Application.put_env(
      :serviceradar_core,
      ServiceRadar.StatusHandler,
      Keyword.put(original, :flow_lane, missing_lane)
    )

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :admission_lane, :rejected],
        fn event, measurements, metadata, pid ->
          send(pid, {:cast_rejected, event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(ServiceRadar.StatusHandler, previous)
    end)

    assert {:error, {:admission_lane_unavailable, _reason}} =
             FlowLane.admit_cast(status("agent-a", "cast"))

    assert_receive {:cast_rejected, [:serviceradar, :admission_lane, :rejected],
                    %{count: 1, payload_bytes: 4},
                    %{lane: :flow_attribution, reason: :lane_unavailable}}
  end

  test "bounded admission telemetry is exported by the core reporter" do
    metric_names = Enum.map(ServiceRadar.Telemetry.admission_lane_metrics(), & &1.name)

    assert [:serviceradar, :admission_lane, :pending, :count] in metric_names
    assert [:serviceradar, :admission_lane, :pending, :bytes] in metric_names
    assert [:serviceradar, :admission_lane, :in_flight, :count] in metric_names
    assert [:serviceradar, :admission_lane, :in_flight, :bytes] in metric_names
    assert [:serviceradar, :admission_lane, :execution, :event, :count] in metric_names
    assert [:serviceradar, :admission_lane, :rejected, :count] in metric_names
    assert [:serviceradar, :admission_lane, :timeout, :count] in metric_names
    assert [:serviceradar, :admission_lane, :crash, :count] in metric_names
  end

  test "invalid deadline and non-positive configurations fail startup" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    invalid_non_positive = lane_opts(task_supervisor, fn _ -> :ok end, max_items: 0)[:config]

    assert {:error, {:non_positive, :max_items}} =
             Lane.validate_config(invalid_non_positive, 10_000)

    invalid_deadline =
      lane_opts(task_supervisor, fn _ -> :ok end,
        queue_wait_ms: 100,
        worker_timeout_ms: 100,
        gateway_call_timeout_ms: 3_199
      )[:config]

    assert {:error, :deadline_budget_exceeded} =
             Lane.validate_config(invalid_deadline, 10_000)

    base = lane_opts(task_supervisor, fn _ -> :ok end, [])[:config]

    assert {:error, {:above_maximum, :queue_wait_ms, 2_000}} =
             Lane.validate_config(Keyword.put(base, :queue_wait_ms, 2_001), 10_000)

    assert {:error, {:above_maximum, :worker_timeout_ms, 20_000}} =
             Lane.validate_config(Keyword.put(base, :worker_timeout_ms, 20_001), 30_000)

    assert {:error, {:above_maximum, :gateway_call_timeout_ms, 25_000}} =
             Lane.validate_config(
               Keyword.put(base, :gateway_call_timeout_ms, 25_001),
               25_000
             )
  end

  test "coordinator couples each lane to its worker supervisor" do
    previous = Application.get_env(:serviceradar_core, :status_handler_enabled)
    Application.put_env(:serviceradar_core, :status_handler_enabled, true)
    on_exit(fn -> restore_env(:status_handler_enabled, previous) end)

    specs =
      Enum.map(
        CoordinatorChildren.children(),
        &Supervisor.child_spec(&1, [])
      )

    ids = Enum.map(specs, & &1.id)

    assert FlowLeaseSupervisor in ids
    assert RetainedPluginLeaseSupervisor in ids
    assert FlowSupervisor in ids
    assert RetainedPluginSupervisor in ids
    refute FlowTaskSupervisor in ids
    refute RetainedPluginTaskSupervisor in ids
    refute FlowLane in ids
    refute RetainedPluginLane in ids
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "a supervised lane restart cannot overlap its previous persistence worker" do
    worker_table = :ets.new(:admission_restart_workers, [:set, :public])
    start_admission_topology(worker_table)

    first_ref = make_ref()
    assert :ok = FlowLane.admit(flow_status("synthetic-first"), {self(), first_ref})

    assert_receive {:flow_persistence_started, "synthetic-first", first_worker, false}

    [%{lease: first_lease}] =
      FlowLane
      |> :sys.get_state()
      |> Map.fetch!(:jobs)
      |> Map.values()

    true = :erlang.suspend_process(first_lease)
    old_lane = Process.whereis(FlowLane)
    Process.exit(old_lane, :kill)

    parent = self()

    spawn(fn ->
      admit_flow_eventually(flow_status("synthetic-second"), parent, 100)
    end)

    assert_receive {:flow_persistence_started, "synthetic-second", second_worker, false}, 1_000

    if Process.alive?(first_lease), do: :erlang.resume_process(first_lease)
    assert_receive {^first_ref, {:error, :coordinator_restart}}, 500

    send(second_worker, {:release_flow, "synthetic-second"})
    assert_receive {:second_admission_result, :ok}, 500
    refute Process.alive?(first_worker)
  end

  test "worker task supervisor restart cannot lose a committed terminal reply" do
    worker_table = :ets.new(:admission_task_restart_workers, [:set, :public])
    start_admission_topology(worker_table)

    reply_ref = make_ref()

    assert :ok =
             FlowLane.admit(flow_status("synthetic-task-restart"), {self(), reply_ref})

    assert_receive {:flow_persistence_started, "synthetic-task-restart", worker, false}

    [%{lease: lease}] =
      FlowLane
      |> :sys.get_state()
      |> Map.fetch!(:jobs)
      |> Map.values()

    true = :erlang.suspend_process(lease)
    send(worker, {:release_flow, "synthetic-task-restart"})

    assert_eventually(fn ->
      case FlowLane |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values() do
        [] -> true
        [%{phase: :delivering}] -> true
        _jobs -> false
      end
    end)

    old_lane = Process.whereis(FlowLane)
    worker_supervisor = Process.whereis(FlowTaskSupervisor)
    Process.exit(worker_supervisor, :kill)

    if Process.alive?(lease), do: :erlang.resume_process(lease)

    assert_receive {^reply_ref, :ok}, 500

    assert_eventually(fn ->
      restarted_lane = Process.whereis(FlowLane)
      is_pid(restarted_lane) and restarted_lane != old_lane
    end)
  end

  test "lane wrapper concurrency cannot be overridden at runtime" do
    flow_tasks =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    plugin_tasks =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    flow_lane =
      start_supervised!(
        {FlowLane,
         name: Module.concat(__MODULE__, "Flow#{System.unique_integer([:positive])}"),
         task_supervisor: flow_tasks,
         concurrency: 99}
      )

    plugin_lane =
      start_supervised!(
        {RetainedPluginLane,
         name: Module.concat(__MODULE__, "Plugin#{System.unique_integer([:positive])}"),
         task_supervisor: plugin_tasks,
         concurrency: 99}
      )

    assert %{
             concurrency: 1,
             config: [
               max_items: 16,
               max_bytes: 67_108_864,
               max_items_per_agent: 4,
               queue_wait_ms: 2_000,
               worker_timeout_ms: 20_000,
               gateway_call_timeout_ms: 25_000
             ]
           } = :sys.get_state(flow_lane)

    assert %{
             concurrency: 2,
             config: [
               max_items: 32,
               max_bytes: 67_108_864,
               max_items_per_agent: 8,
               queue_wait_ms: 2_000,
               worker_timeout_ms: 20_000,
               gateway_call_timeout_ms: 30_000
             ]
           } = :sys.get_state(plugin_lane)
  end

  defp start_lane(processor, overrides \\ []) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    opts = lane_opts(task_supervisor, processor, overrides)
    start_supervised!(Supervisor.child_spec({Lane, opts}, id: make_ref()))
  end

  defp lane_opts(task_supervisor, processor, overrides) do
    source_max_bytes = Keyword.get(overrides, :source_max_bytes, 1_024)

    config =
      Keyword.merge(
        [
          max_items: 4,
          max_bytes: 64 * 1_024,
          max_items_per_agent: 4,
          queue_wait_ms: 100,
          worker_timeout_ms: 100,
          gateway_call_timeout_ms: 3_200
        ],
        Keyword.delete(overrides, :source_max_bytes)
      )

    [
      lane: :test,
      concurrency: 1,
      task_supervisor: task_supervisor,
      processor: processor,
      source_max_bytes: source_max_bytes,
      gateway_max_ms: 10_000,
      config: config
    ]
  end

  defp admit(lane, status) do
    reply_ref = make_ref()
    assert :ok = Lane.admit(lane, status, {self(), reply_ref})
    reply_ref
  end

  defp status(agent_id, message), do: %{agent_id: agent_id, message: message}

  defp flow_status(partition) do
    %{
      source: "flow-attribution",
      service_type: "passive-netprobe",
      service_name: "flow-attribution",
      agent_id: "agent-synthetic",
      partition: partition,
      message:
        FlowAttributionEventBatch.encode(%FlowAttributionEventBatch{
          events: [
            %FlowAttributionEvent{
              local_ip: "192.0.2.10",
              local_port: 50_000,
              remote_ip: "198.51.100.20",
              remote_port: 443,
              transport_protocol: "TCP",
              pid: 42,
              comm: "synthetic-client"
            }
          ]
        })
    }
  end

  def hold_flow_persistence(_events, partition, _agent_id, parent, worker_table) do
    previous_worker_alive? =
      case partition do
        "synthetic-first" ->
          true = :ets.insert(worker_table, {:previous_worker, self()})
          false

        "synthetic-second" ->
          [{:previous_worker, previous_worker}] = :ets.lookup(worker_table, :previous_worker)
          Process.alive?(previous_worker)

        _partition ->
          false
      end

    send(
      parent,
      {:flow_persistence_started, partition, self(), previous_worker_alive?}
    )

    receive do
      {:release_flow, ^partition} -> :ok
    end
  end

  defp admit_flow_eventually(_status, parent, 0),
    do: send(parent, {:second_admission_result, :unavailable})

  defp admit_flow_eventually(status, parent, attempts) do
    reply_ref = make_ref()

    case FlowLane.admit(status, {self(), reply_ref}) do
      :ok ->
        receive do
          {^reply_ref, result} -> send(parent, {:second_admission_result, result})
        end

      {:error, {:admission_lane_unavailable, _reason}} ->
        Process.sleep(10)
        admit_flow_eventually(status, parent, attempts - 1)
    end
  end

  defp start_admission_topology(worker_table) do
    previous_handler = Application.get_env(:serviceradar_core, ServiceRadar.StatusHandler)
    previous_enabled = Application.get_env(:serviceradar_core, :status_handler_enabled)

    Application.put_env(:serviceradar_core, :status_handler_enabled, true)

    handler_config =
      (previous_handler || [])
      |> Keyword.delete(:flow_lane)
      |> Keyword.put(
        :flow_attribution_persister,
        {__MODULE__, :hold_flow_persistence, [self(), worker_table]}
      )

    Application.put_env(:serviceradar_core, ServiceRadar.StatusHandler, handler_config)

    on_exit(fn ->
      restore_env(ServiceRadar.StatusHandler, previous_handler)
      restore_env(:status_handler_enabled, previous_enabled)
    end)

    admission_ids = [
      FlowTaskSupervisor,
      RetainedPluginTaskSupervisor,
      FlowLeaseSupervisor,
      RetainedPluginLeaseSupervisor,
      FlowSupervisor,
      RetainedPluginSupervisor,
      FlowLane,
      RetainedPluginLane
    ]

    admission_children =
      CoordinatorChildren.children()
      |> Enum.map(&Supervisor.child_spec(&1, []))
      |> Enum.filter(&(&1.id in admission_ids))

    topology = %{
      id: make_ref(),
      start: {Supervisor, :start_link, [admission_children, [strategy: :one_for_one]]}
    }

    start_supervised!(topology)
  end

  defp held_processor(parent) do
    fn status ->
      send(parent, {:started, status.message, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp delayed_link_exit_processor(parent, delay_ms) do
    fn status ->
      Process.flag(:trap_exit, true)
      send(parent, {:started, status.message, self()})

      receive do
        :release ->
          :ok

        {:EXIT, _lease, _reason} ->
          Process.sleep(delay_ms)
          :ok
      end
    end
  end

  defp capture_lane_state(lane \\ :test) do
    parent = self()
    capture_ref = make_ref()
    handler_id = {__MODULE__, capture_ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :admission_lane, :state],
        fn _event, measurements, metadata, {pid, ref} ->
          if metadata[:lane] == lane, do: send(pid, {:lane_state, ref, measurements})
        end,
        {parent, capture_ref}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    capture_ref
  end

  defp assert_occupied_then_empty(capture_ref) do
    occupied = receive_occupied_state(capture_ref)

    assert occupied.pending_count + occupied.in_flight_count > 0
    assert occupied.pending_bytes + occupied.in_flight_bytes > 0

    assert_receive {:lane_state, ^capture_ref,
                    %{
                      pending_count: 0,
                      pending_bytes: 0,
                      in_flight_count: 0,
                      in_flight_bytes: 0
                    }},
                   500
  end

  defp receive_occupied_state(capture_ref) do
    receive do
      {:lane_state, ^capture_ref,
       %{
         pending_count: pending_count,
         pending_bytes: pending_bytes,
         in_flight_count: in_flight_count,
         in_flight_bytes: in_flight_bytes
       } = measurements} ->
        if pending_count + in_flight_count > 0 and pending_bytes + in_flight_bytes > 0 do
          measurements
        else
          receive_occupied_state(capture_ref)
        end
    after
      500 -> flunk("expected positive lane item and byte occupancy")
    end
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}_#{System.unique_integer([:positive])}")

  defp assert_eventually(fun, attempts \\ 30)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_empty(lane) do
    assert_eventually(fn ->
      match?(
        %{jobs: jobs, running: running, admitted_bytes: 0} when jobs == %{} and running == %{},
        :sys.get_state(lane)
      )
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
