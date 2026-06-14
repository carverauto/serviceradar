defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine do
  @moduledoc """
  Native shard-resource anomaly context engine.

  The GenServer owns the shard resources and serializes batch calls before they
  cross into Rust. That keeps mutable detector state inside Rust without letting
  concurrent Broadway processors contend on the same native shard resource.
  """

  use GenServer

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.BatchPreparation
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Checkpoint
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Config
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Context
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Evaluation
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Retention
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Runtime
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.ShardEvaluator
  alias ServiceRadar.Observability.AnomalyDetection.Telemetry, as: AnomalyTelemetry
  alias ServiceRadar.Observability.CausalReasoner

  require Logger

  @type sample :: ServiceRadar.Observability.AnomalyDetection.SampleExtractor.sample()
  @type compact_sample ::
          {non_neg_integer(), String.t() | nil, term(), number(), non_neg_integer() | nil,
           map() | nil}
  @type prepared_sample ::
          {non_neg_integer(), String.t(), CausalReasoner.context() | nil, number(),
           non_neg_integer() | nil}
  @type prepared_shard_batch :: {non_neg_integer(), [prepared_sample()]}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Fix (review #3799): restart transiently so a crash restarts the engine
      # under its supervisor instead of being treated as a permanent worker
      # (parity with ContextOwner's transient owners).
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Fix (review #MAJOR/#3799 fault isolation + recovery): trap exits so a
    # dying linked shard worker is reported as an {:EXIT, ...} message we can
    # handle (restart that one shard) instead of taking the whole engine down,
    # and so terminate/2 runs its cleanup/persistence hook on shutdown.
    Process.flag(:trap_exit, true)

    state = Runtime.setup(opts, Config.runtime())

    # Fix (review #MAJOR hot-path pruning): drive series/token eviction from a
    # periodic timer rather than on every evaluate call. The per-evaluate path
    # only ever performs a small, budgeted eviction; the heavy TTL sweep is here.
    schedule_prune(state)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    state
    |> Checkpoint.cancel_flush()
    |> Checkpoint.flush_pending(Config.seen_events_table())

    Runtime.teardown(Config.runtime())

    :ok
  end

  @impl true
  def handle_call({:evaluate_events_batch, samples}, _from, state) do
    started_at = System.monotonic_time()
    {reply, state} = Evaluation.events(samples, state, Context.evaluation())
    AnomalyTelemetry.emit_batch_completed(:events, started_at, length(samples), reply)
    {:reply, reply, state}
  end

  def handle_call({:evaluate_events_batch_profiled, samples}, _from, state) do
    started_at = System.monotonic_time()
    {reply, state, profile} = Evaluation.events_profiled(samples, state, Context.evaluation())
    AnomalyTelemetry.emit_batch_completed(:events_profiled, started_at, length(samples), reply)
    {:reply, {reply, profile}, state}
  end

  def handle_call({:evaluate_compact_events_batch, samples}, _from, state) do
    started_at = System.monotonic_time()
    {reply, state} = Evaluation.compact_events(samples, state, Context.evaluation())
    AnomalyTelemetry.emit_batch_completed(:compact_events, started_at, length(samples), reply)
    {:reply, reply, state}
  end

  def handle_call({:evaluate_compact_events_batch_profiled, samples}, _from, state) do
    started_at = System.monotonic_time()

    {reply, state, profile} =
      Evaluation.compact_events_profiled(samples, state, Context.evaluation())

    AnomalyTelemetry.emit_batch_completed(
      :compact_events_profiled,
      started_at,
      length(samples),
      reply
    )

    {:reply, {reply, profile}, state}
  end

  @impl true
  def handle_info(:flush_checkpoint, state) do
    state =
      state
      |> Map.put(:checkpoint_flush_ref, nil)
      |> Checkpoint.flush_pending(Config.seen_events_table())

    {:noreply, state}
  end

  def handle_info(:prune, state) do
    # Fix (review #MAJOR hot-path pruning): periodic, incremental eviction. Both
    # the series LRU and the idempotency tokens are pruned here off the hot
    # path, bounded by the eviction budget, so we never copy the full table.
    state =
      state
      |> Retention.enforce_series_limit_periodic(Context.retention_tables())
      |> Retention.prune_seen_events(Config.seen_events_table())

    schedule_prune(state)
    {:noreply, state}
  end

  # Fix (review #3820 fault isolation): a shard worker exiting (crash or a wedged
  # worker we killed) arrives here because we trap exits. Restart only that
  # shard's worker and swap it in both the state map and the persistent_term
  # tuple used by the lock-free evaluate path, preserving per-shard isolation
  # instead of crashing the whole engine.
  def handle_info({:EXIT, pid, reason}, %{workers: workers} = state) when is_tuple(workers) do
    case ShardEvaluator.worker_index(workers, pid) do
      nil ->
        # Not one of our shard workers (e.g. a transient linked helper). Mirror
        # ContextOwner: a non-normal linked exit still stops the engine so the
        # supervisor can restart it cleanly.
        if reason in [:normal, :shutdown] do
          {:noreply, state}
        else
          {:stop, reason, state}
        end

      shard_index ->
        Logger.warning("native anomaly shard worker exited; restarting shard",
          shard_index: shard_index,
          reason: inspect(reason)
        )

        new_worker = ShardEvaluator.start_worker(elem(state.resources, shard_index))
        workers = put_elem(workers, shard_index, new_worker)
        :persistent_term.put(Config.workers_key(), workers)
        {:noreply, %{state | workers: workers}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Evaluates samples and returns only anomaly/clear state-change events.
  """
  @spec evaluate_events_batch([sample()]) :: [
          {sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
        ]
  def evaluate_events_batch(samples) when is_list(samples) do
    GenServer.call(__MODULE__, {:evaluate_events_batch, samples}, :infinity)
  end

  @doc false
  @spec evaluate_events_batch_profiled([sample()]) ::
          {[
             {sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
           ], map()}
  def evaluate_events_batch_profiled(samples) when is_list(samples) do
    GenServer.call(__MODULE__, {:evaluate_events_batch_profiled, samples}, :infinity)
  end

  @doc """
  Evaluates compact event samples and returns only anomaly/clear state-change events.

  Compact samples are `{index, series_key, event_key, value, observed_at_unix_nano, series_config}`
  tuples. The `index` must be the zero-based position in the batch; it is used to
  recover metadata only for sparse emitted events.
  """
  @spec evaluate_compact_events_batch([compact_sample()]) :: [
          {compact_sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
        ]
  def evaluate_compact_events_batch(samples) when is_list(samples) do
    GenServer.call(__MODULE__, {:evaluate_compact_events_batch, samples}, :infinity)
  end

  @doc false
  @spec evaluate_compact_events_batch_profiled([compact_sample()]) ::
          {[
             {compact_sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
           ], map()}
  def evaluate_compact_events_batch_profiled(samples) when is_list(samples) do
    GenServer.call(__MODULE__, {:evaluate_compact_events_batch_profiled, samples}, :infinity)
  end

  @doc """
  Evaluates shard-ready compact native inputs.

  This API is intentionally lower-level than `evaluate_compact_events_batch/1`:
  callers provide `{shard_index, inputs}` batches where each input is already in
  the native tuple shape `{index, series_key, context_or_nil, value, observed_at}`.
  The engine does not regroup rich sample maps or recover sample metadata for
  clean non-events.
  """
  @spec evaluate_prepared_shard_batches([prepared_shard_batch()]) :: [
          CausalReasoner.indexed_event_result()
        ]
  def evaluate_prepared_shard_batches(shard_batches) when is_list(shard_batches) do
    started_at = System.monotonic_time()
    shard_count = Context.shard_count()
    workers = Context.workers()

    results =
      shard_batches
      |> BatchPreparation.prepared_groups(shard_count)
      |> evaluate_shard_groups(workers)

    AnomalyTelemetry.emit_batch_completed(
      :prepared_shards,
      started_at,
      prepared_input_count(shard_batches),
      results
    )

    results
  end

  defp prepared_input_count(shard_batches) do
    Enum.reduce(shard_batches, 0, fn
      {_shard_index, inputs}, acc when is_list(inputs) -> acc + length(inputs)
      _invalid, acc -> acc
    end)
  end

  defp evaluate_shard_groups(groups, workers) do
    timeout = Config.shard_eval_timeout_ms(Context.opts())
    ShardEvaluator.evaluate_groups(groups, workers, timeout)
  end

  defp schedule_prune(%{event_prune_interval_ms: interval}) when interval > 0 do
    Process.send_after(self(), :prune, interval)
  end

  defp schedule_prune(_state), do: :ok
end
