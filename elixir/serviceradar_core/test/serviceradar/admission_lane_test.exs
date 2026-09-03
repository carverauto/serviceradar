defmodule ServiceRadar.AdmissionLaneTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Admission.RetainedPluginLane

  test "count, byte, per-agent, and source limits return distinct reasons" do
    parent = self()
    processor = held_processor(parent)

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
  end

  test "a crashing worker releases capacity and returns worker_crash" do
    lane = start_lane(fn _status -> exit(:forced_crash) end, max_items: 1)
    reply_ref = admit(lane, status("agent-a", "crash"))

    assert_receive {^reply_ref, {:error, :worker_crash}}, 250

    next_ref = admit(lane, status("agent-b", "also-crash"))
    assert_receive {^next_ref, {:error, :worker_crash}}, 250
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

  test "state telemetry returns to zero after work completes" do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :admission_lane, :state],
        fn event, measurements, metadata, pid ->
          send(pid, {:lane_state, event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    lane = start_lane(fn _ -> :ok end)
    reply_ref = admit(lane, status("agent-a", "telemetry"))
    assert_receive {^reply_ref, :ok}

    assert_eventually(fn ->
      receive do
        {:lane_state, _event,
         %{pending_count: 0, pending_bytes: 0, in_flight_count: 0, in_flight_bytes: 0},
         %{lane: :test}} ->
          true
      after
        0 -> false
      end
    end)
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

  test "coordinator supervises both lane coordinators and their task supervisors" do
    previous = Application.get_env(:serviceradar_core, :status_handler_enabled)
    Application.put_env(:serviceradar_core, :status_handler_enabled, true)
    on_exit(fn -> restore_env(:status_handler_enabled, previous) end)

    specs =
      Enum.map(
        ServiceRadar.Cluster.CoordinatorChildren.children(),
        &Supervisor.child_spec(&1, [])
      )

    ids = Enum.map(specs, & &1.id)

    assert ServiceRadar.Admission.FlowTaskSupervisor in ids
    assert ServiceRadar.Admission.RetainedPluginTaskSupervisor in ids
    assert FlowLane in ids
    assert RetainedPluginLane in ids
    assert length(ids) == length(Enum.uniq(ids))
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

  defp held_processor(parent) do
    fn status ->
      send(parent, {:started, status.message, self()})

      receive do
        :release -> :ok
      end
    end
  end

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
