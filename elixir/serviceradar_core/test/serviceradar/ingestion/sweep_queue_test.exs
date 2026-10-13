defmodule ServiceRadar.Ingestion.SweepQueueTest do
  @moduledoc """
  The sweep result queue, driven through the reserve/submit protocol the
  gateway uses. An invented processor stands in for the database ingestor, and
  every agent, sweep group and address is synthetic.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Ingestion.Admission
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Ingestion.SweepQueue
  alias ServiceRadar.StatusHandler

  @moduletag :capture_log

  # The release evaluates serviceradar_core_elx's runtime config, not this app's.
  @runtime_config Path.expand("../../../../serviceradar_core_elx/config/runtime.exs", __DIR__)
  @external_resource @runtime_config

  @release_env %{
    "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/sweep_queue_config_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false",
    "SERVICERADAR_SWEEP_INGESTION_MAX_ITEMS" => nil,
    "SERVICERADAR_SWEEP_INGESTION_MAX_ITEMS_PER_AGENT" => nil,
    "SERVICERADAR_SWEEP_INGESTION_WORKER_TIMEOUT_MS" => nil
  }

  defmodule RecordingSweepIngestor do
    @moduledoc false
    # Stands in for SweepResultsIngestor behind the real admission path.
    def ingest_results(results, _execution_id, opts) do
      send(
        Application.fetch_env!(:serviceradar_core, :sweep_queue_test_pid),
        {:sweep_ingested, opts[:agent_id], opts[:chunk_index]}
      )

      Process.sleep(Application.get_env(:serviceradar_core, :sweep_queue_test_delay_ms, 0))
      {:ok, %{hosts_total: length(results)}}
    end
  end

  test "a burst longer than the old admission wait is acknowledged at once and kept in order" do
    queue = start_queue(recording_processor(self(), 200))
    chunks = burst("agent-a", 14)

    started = System.monotonic_time(:millisecond)
    results = Enum.map(chunks, &deliver(queue, &1))

    # 14 chunks at 200 ms each outlast the two-second wait that used to drop them.
    assert Enum.all?(results, &(&1 == :ok))
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert ingested_in_order("agent-a", 14, 5_000) == Enum.to_list(0..13)
    assert_drained(queue)
  end

  test "bursts from two agents interleave without loss" do
    queue = start_queue(recording_processor(self(), 50))
    first = burst("agent-a", 10)
    second = burst("agent-b", 10)

    deliveries =
      [first, second]
      |> Enum.map(fn chunks -> Task.async(fn -> Enum.map(chunks, &deliver(queue, &1)) end) end)
      |> Task.await_many(5_000)

    assert Enum.all?(List.flatten(deliveries), &(&1 == :ok))

    order = receive_ingested(20, 5_000)
    assert for({"agent-a", index} <- order, do: index) == Enum.to_list(0..9)
    assert for({"agent-b", index} <- order, do: index) == Enum.to_list(0..9)

    # Neither agent waited for the other's whole burst.
    positions = Enum.with_index(order)
    first_b = Enum.min(for {{"agent-b", _}, position} <- positions, do: position)
    last_a = Enum.max(for {{"agent-a", _}, position} <- positions, do: position)
    assert first_b < last_a
    assert_drained(queue)
  end

  test "a full queue rejects reservations and a retrying caller still delivers in order" do
    queue = start_queue(recording_processor(self(), 30), max_items_per_agent: 3)

    {rejections, delivered} = deliver_with_retry(queue, burst("agent-a", 10), 20)

    assert delivered == 10
    assert rejections != []
    assert Enum.all?(rejections, &(&1 == :per_agent_full))
    assert ingested_in_order("agent-a", 10, 5_000) == Enum.to_list(0..9)
    assert_drained(queue)
  end

  test "each capacity limit rejects the reservation with its own reason" do
    parent = self()
    held = held_processor(parent)

    count_queue = start_queue(held, max_items: 2)
    assert :ok = deliver(count_queue, status("agent-a", 0, "one"))
    assert :ok = deliver(count_queue, status("agent-b", 0, "two"))
    assert {:error, :count_full} = deliver(count_queue, status("agent-c", 0, "three"))

    agent_queue = start_queue(held, max_items_per_agent: 1)
    assert :ok = deliver(agent_queue, status("agent-a", 0, "one"))
    assert {:error, :per_agent_full} = deliver(agent_queue, status("agent-a", 1, "two"))
    assert :ok = deliver(agent_queue, status("agent-b", 0, "three"))

    small = status("agent-a", 0, "12345")
    byte_queue = start_queue(held, max_bytes: Lane.descriptor(small, 1).retained_bytes)
    assert :ok = deliver(byte_queue, small)
    assert {:error, :configured_byte_full} = deliver(byte_queue, status("agent-b", 0, "1"))

    oversized = status("agent-a", 0, String.duplicate("x", 16 * 1_024 * 1_024 + 1))
    assert {:error, :wire_payload_too_large} = deliver(agent_queue, oversized)

    release_started(5)
    Enum.each([count_queue, agent_queue, byte_queue], &assert_drained/1)
  end

  test "default sweep byte credit stops one agent filling the queue" do
    queue = start_queue(held_processor(self()))
    nine_mib = String.duplicate("a", 9 * 1_024 * 1_024)

    assert :ok = deliver(queue, status("agent-a", 0, nine_mib))
    assert {:error, :per_agent_byte_full} = deliver(queue, status("agent-a", 1, nine_mib))
    assert :ok = deliver(queue, status("agent-b", 0, nine_mib))

    release_started(2)
    assert_drained(queue)
  end

  test "an attempt that overruns its deadline is killed before its retry starts" do
    attempts = start_supervised!({Agent, fn -> %{} end})
    parent = self()

    processor = fn status ->
      attempt = Agent.get_and_update(attempts, &bump(&1, status.chunk_index))
      send(parent, {:attempt, status.chunk_index, attempt, self()})
      if status.chunk_index == 0 and attempt == 1, do: Process.sleep(:infinity)
      send(parent, {:ingested, status.agent_id, status.chunk_index})
      :ok
    end

    queue = start_queue(processor, worker_timeout_ms: 100, retry_delay_ms: 0)

    log =
      capture_log(fn ->
        Enum.each(burst("agent-a", 3), &(:ok = deliver(queue, &1)))
        assert_receive {:attempt, 0, 1, hung}, 1_000
        assert_receive {:attempt, 0, 2, _retry}, 1_000
        refute Process.alive?(hung)
        assert ingested_in_order("agent-a", 3, 2_000) == [0, 1, 2]
        assert_drained(queue)
      end)

    assert log =~ "ended with execution_timeout; retrying"
  end

  test "a chunk that fails every attempt is dropped and logged, and its group moves on" do
    parent = self()

    processor = fn status ->
      if status.chunk_index == 0, do: Process.sleep(:infinity)
      send(parent, {:ingested, status.agent_id, status.chunk_index})
      :ok
    end

    queue = start_queue(processor, worker_timeout_ms: 100, max_attempts: 2, retry_delay_ms: 0)

    log =
      capture_log(fn ->
        Enum.each(burst("agent-a", 3), &(:ok = deliver(queue, &1)))
        assert ingested_in_order("agent-a", 2, 2_000) == [1, 2]
        assert_drained(queue)
      end)

    assert log =~ "Sweep result chunk dropped after 2 attempts ending with execution_timeout"
    assert log =~ "chunk_index 0 of 3"
  end

  test "a crashed attempt is retried, while an error result is final" do
    attempts = start_supervised!({Agent, fn -> %{} end})
    parent = self()

    processor = fn status ->
      attempt = Agent.get_and_update(attempts, &bump(&1, status.chunk_index))

      case {status.chunk_index, attempt} do
        {0, 1} ->
          raise "synthetic ingest crash"

        {1, _} ->
          send(parent, {:failed, status.chunk_index, attempt})
          {:error, :synthetic_rejection}

        _ ->
          send(parent, {:ingested, status.agent_id, status.chunk_index})
          :ok
      end
    end

    queue = start_queue(processor, retry_delay_ms: 0)

    log =
      capture_log(fn ->
        Enum.each(burst("agent-a", 3), &(:ok = deliver(queue, &1)))
        assert ingested_in_order("agent-a", 2, 2_000) == [0, 2]
        assert_drained(queue)
      end)

    assert_received {:failed, 1, 1}
    refute_received {:failed, 1, 2}
    assert Agent.get(attempts, & &1) == %{0 => 2, 1 => 1, 2 => 1}
    assert log =~ "ended with worker_crash; retrying"
    assert log =~ "will not be retried"
  end

  test "reservations expire, follow their owner, and can be cancelled" do
    queue = start_queue(held_processor(self()))
    chunk = status("agent-a", 0, "payload")

    # A reservation that is never submitted gives its capacity back.
    assert {:ok, {^queue, expired}} =
             Lane.reserve(queue, Lane.descriptor(chunk, 50), self(), 1_000)

    assert_drained(queue)
    assert {:error, :reservation_expired} = submit(queue, expired, chunk)

    owner = spawn(fn -> receive(do: (:stop -> :ok)) end)

    assert {:ok, {^queue, _orphan}} =
             Lane.reserve(queue, Lane.descriptor(chunk, 15_000), owner, 1_000)

    send(owner, :stop)
    assert_drained(queue)

    call_ref = make_ref()

    assert {:ok, {^queue, _cancelled}} =
             GenServer.call(
               queue,
               {:reserve, Lane.descriptor(chunk, 15_000), self(), 1_000, call_ref}
             )

    Lane.cancel_ref(queue, call_ref)
    assert_drained(queue)

    # A queued chunk that its caller cancelled never runs.
    assert :ok = deliver(queue, status("agent-a", 0, "running"))
    assert_receive {:started, "running", worker}, 1_000
    {:ok, {^queue, queued}} = Lane.reserve(queue, Lane.descriptor(chunk, 15_000), self(), 1_000)
    assert :ok = submit(queue, queued, chunk)
    Lane.cancel(queue, queued)
    send(worker, :release)
    assert_drained(queue)
    refute_received {:started, "payload", _}
  end

  test "a submit that does not match its reservation is refused" do
    queue = start_queue(held_processor(self()))
    chunk = status("agent-a", 0, "payload")

    {:ok, {^queue, mismatched}} =
      Lane.reserve(queue, Lane.descriptor(chunk, 15_000), self(), 1_000)

    assert {:error, :reservation_payload_mismatch} =
             submit(queue, mismatched, status("agent-a", 0, "a different payload"))

    {:ok, {^queue, invalid}} = Lane.reserve(queue, Lane.descriptor(chunk, 15_000), self(), 1_000)

    assert {:error, :invalid_admission_mode} =
             GenServer.call(queue, {:submit, invalid, chunk, :later})

    {:ok, {^queue, stale}} = Lane.reserve(queue, Lane.descriptor(chunk, 15_000), self(), 1_000)
    Process.sleep(30)

    assert {:error, :admission_timeout} =
             GenServer.call(queue, {:submit, stale, chunk, :best_effort, 10})

    Lane.cancel(queue, invalid)
    assert_drained(queue)
  end

  test "queue depth and outcomes report under the sweep lane" do
    start_supervised!(
      {RuntimeMetrics,
       interval_ms: 3_600_000, publish_opts: [request: fn _, _, _ -> {:error, :unused} end]}
    )

    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :admission_lane, :state],
        fn _event, measurements, %{lane: lane}, pid ->
          if lane == :sweep, do: send(pid, {:sweep_state, measurements})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    queue = start_queue(recording_processor(parent, 20), max_items_per_agent: 2)
    [first, second, third] = burst("agent-a", 3)
    assert :ok = deliver(queue, first)
    assert :ok = deliver(queue, second)
    assert {:error, :per_agent_full} = deliver(queue, third)
    assert_receive {:sweep_state, %{in_flight_count: 1, pending_count: 1}}, 1_000
    assert ingested_in_order("agent-a", 2, 2_000) == [0, 1]
    assert_drained(queue)

    assert %{pending_count: 0, pending_bytes: 0, in_flight_count: 0, in_flight_bytes: 0} =
             last_sweep_state()

    assert counter(:events, :admitted) == 2
    assert counter(:events, :rejected) == 1
    assert counter(:rejection, :per_agent_full) == 1
    assert counter(:events, :completion) == 2
    assert counter(:outcome, :accepted) == 2
  end

  test "invalid limits stop the queue" do
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_sweep_queue_config, {:non_positive, :max_attempts}}} =
             SweepQueue.start_link(task_supervisor: tasks, config: [max_attempts: 0])

    assert {:error, {:invalid_sweep_queue_config, {:negative, :retry_delay_ms}}} =
             SweepQueue.start_link(task_supervisor: tasks, config: [retry_delay_ms: -1])
  end

  describe "deployed runtime configuration" do
    test "sizes the queue from the environment and keeps its defaults when unset" do
      keys = [:max_items, :max_items_per_agent, :worker_timeout_ms]

      assert Keyword.take(release_limits(%{}), keys) ==
               [max_items: 128, max_items_per_agent: 32, worker_timeout_ms: 60_000]

      tuned =
        release_limits(%{
          "SERVICERADAR_SWEEP_INGESTION_MAX_ITEMS" => "256",
          "SERVICERADAR_SWEEP_INGESTION_MAX_ITEMS_PER_AGENT" => "48",
          "SERVICERADAR_SWEEP_INGESTION_WORKER_TIMEOUT_MS" => "90000"
        })

      assert Keyword.take(tuned, keys) ==
               [max_items: 256, max_items_per_agent: 48, worker_timeout_ms: 90_000]
    end

    test "an invalid size fails closed" do
      assert_raise ArgumentError, ~r/SERVICERADAR_SWEEP_INGESTION_WORKER_TIMEOUT_MS/, fn ->
        release_limits(%{"SERVICERADAR_SWEEP_INGESTION_WORKER_TIMEOUT_MS" => "0"})
      end
    end
  end

  describe "behind the status handler" do
    setup do
      keys = [
        :sweep_ingestor,
        :sweep_queue_test_pid,
        :sweep_queue_test_delay_ms,
        :results_router_batching,
        :results_router_flush_interval_ms
      ]

      previous = Map.new(keys, &{&1, Application.fetch_env(:serviceradar_core, &1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:serviceradar_core, key, value)
          {key, :error} -> Application.delete_env(:serviceradar_core, key)
        end)
      end)

      Application.put_env(:serviceradar_core, :sweep_ingestor, RecordingSweepIngestor)
      Application.put_env(:serviceradar_core, :sweep_queue_test_pid, self())
      Application.put_env(:serviceradar_core, :sweep_queue_test_delay_ms, 200)
      # Completed service state is batched for the database, which this tier
      # does not have; keep the batch buffered for the length of the test.
      Application.put_env(:serviceradar_core, :results_router_batching, true)
      Application.put_env(:serviceradar_core, :results_router_flush_interval_ms, 600_000)

      ServiceRadar.TestSupport.start_ingestion_topology!()
      :ok
    end

    test "a gateway burst reaches the sweep ingestor whole and in order" do
      group = Ecto.UUID.generate()

      results =
        Enum.map(0..13, fn index ->
          chunk = Admission.prepare(gateway_chunk("agent-a", group, index, 14))
          descriptor = Lane.descriptor(chunk, Admission.budget_ms())

          with {:ok, {owner, id}} <-
                 GenServer.call(StatusHandler, {:reserve_status, descriptor}, 1_100) do
            GenServer.call(owner, {:submit, id, chunk, :best_effort}, 15_000)
          end
        end)

      assert results == List.duplicate(:ok, 14)

      indices =
        for _ <- 0..13 do
          assert_receive {:sweep_ingested, "agent-a", index}, 5_000
          index
        end

      assert indices == Enum.to_list(0..13)
      assert_drained(GenServer.whereis(Admission.server(:sweep)))
    end
  end

  # Evaluates the release runtime config under `environment`, then resolves the
  # queue limits from the ingestion configuration it produced.
  defp release_limits(environment) do
    environment = Map.merge(@release_env, environment)
    previous_env = Map.new(environment, fn {name, _value} -> {name, System.get_env(name)} end)
    key = ServiceRadar.Ingestion.Supervisor
    previous_config = Application.fetch_env(:serviceradar_core, key)
    Enum.each(environment, &put_system_env/1)

    try do
      config = Config.Reader.read!(@runtime_config, env: :prod)[:serviceradar_core][key]
      Application.put_env(:serviceradar_core, key, config)
      SweepQueue.limits()
    after
      Enum.each(previous_env, &put_system_env/1)

      case previous_config do
        {:ok, config} -> Application.put_env(:serviceradar_core, key, config)
        :error -> Application.delete_env(:serviceradar_core, key)
      end
    end
  end

  defp put_system_env({name, nil}), do: System.delete_env(name)
  defp put_system_env({name, value}), do: System.put_env(name, value)

  defp start_queue(processor, config \\ []) do
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    start_supervised!(
      Supervisor.child_spec(
        {SweepQueue,
         task_supervisor: tasks, processor: processor, execution_gate: nil, config: config},
        id: make_ref()
      )
    )
  end

  # The gateway's best-effort path: reserve with a metadata descriptor, then
  # hand the payload to the owner that granted the reservation.
  defp deliver(queue, status) do
    with {:ok, {owner, id}} <-
           Lane.reserve(queue, Lane.descriptor(status, 15_000), self(), 1_000) do
      submit(owner, id, status)
    end
  end

  defp submit(queue, id, status),
    do: GenServer.call(queue, {:submit, id, status, :best_effort}, 1_000)

  # The gateway's status buffer: a rejected status stays at the head of the
  # buffer and the flush pauses until the next interval.
  defp deliver_with_retry(queue, statuses, interval_ms, rejections \\ [], delivered \\ 0)

  defp deliver_with_retry(_queue, [], _interval_ms, rejections, delivered),
    do: {Enum.reverse(rejections), delivered}

  defp deliver_with_retry(queue, [status | rest] = pending, interval_ms, rejections, delivered) do
    case deliver(queue, status) do
      :ok ->
        deliver_with_retry(queue, rest, interval_ms, rejections, delivered + 1)

      {:error, reason} ->
        Process.sleep(interval_ms)
        deliver_with_retry(queue, pending, interval_ms, [reason | rejections], delivered)
    end
  end

  defp recording_processor(parent, delay_ms) do
    fn status ->
      Process.sleep(delay_ms)
      send(parent, {:ingested, status.agent_id, status.chunk_index})
      :ok
    end
  end

  defp held_processor(parent) do
    fn status ->
      send(parent, {:started, status.message, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp release_started(count) do
    for _ <- 1..count do
      assert_receive {:started, _message, worker}, 1_000
      send(worker, :release)
    end
  end

  defp ingested_in_order(agent_id, count, timeout) do
    for _ <- 1..count do
      assert_receive {:ingested, ^agent_id, index}, timeout
      index
    end
  end

  defp receive_ingested(count, timeout) do
    for _ <- 1..count do
      assert_receive {:ingested, agent_id, index}, timeout
      {agent_id, index}
    end
  end

  defp burst(agent_id, total) do
    group = Ecto.UUID.generate()

    for index <- 0..(total - 1),
        do: Admission.prepare(gateway_chunk(agent_id, group, index, total))
  end

  defp gateway_chunk(agent_id, group, index, total) do
    payload = %{
      "sweep_group_id" => group,
      "execution_id" => Ecto.UUID.generate(),
      "hosts" => [%{"host" => "192.0.2.#{index + 1}", "available" => true}]
    }

    %{
      source: "results",
      service_type: "sweep",
      service_name: "sweep",
      agent_id: agent_id,
      gateway_id: "gateway01.example.com",
      partition: "default",
      chunk_index: index,
      total_chunks: total,
      is_final: index == total - 1,
      message: Jason.encode!(payload)
    }
  end

  defp status(agent_id, index, message) do
    %{
      source: "results",
      service_type: "sweep",
      agent_id: agent_id,
      chunk_index: index,
      message: message
    }
  end

  defp bump(attempts, index) do
    attempt = Map.get(attempts, index, 0) + 1
    {attempt, Map.put(attempts, index, attempt)}
  end

  defp last_sweep_state(last \\ nil) do
    receive do
      {:sweep_state, measurements} -> last_sweep_state(measurements)
    after
      0 -> last
    end
  end

  defp counter(kind, name) do
    case :ets.lookup(RuntimeMetrics, {kind, :sweep, name}) do
      [{_key, value}] -> value
      [] -> 0
    end
  end

  defp assert_drained(queue) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait_drained(queue, deadline)
  end

  defp wait_drained(queue, deadline) do
    case :sys.get_state(queue) do
      %{jobs: jobs, running: running, bytes: 0} when jobs == %{} and running == %{} ->
        :ok

      state ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("sweep queue did not drain: #{map_size(state.jobs)} jobs remain")
        end

        Process.sleep(10)
        wait_drained(queue, deadline)
    end
  end
end
