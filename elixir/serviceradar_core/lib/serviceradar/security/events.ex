defmodule ServiceRadar.Security.Events do
  @moduledoc """
  Non-blocking recorder for `ServiceRadar.Security.SecurityEvent`.

  Callers on the request hot path invoke `record/1` (and friends),
  which casts to a per-node GenServer. The GenServer batches inserts
  and persists them via Ash so the request path is never blocked on
  Postgres latency. Under sustained overflow events are dropped and
  the `[:serviceradar, :security, :events, :dropped]` telemetry
  counter is incremented rather than blocking the caller.

  The recorder broadcasts inserted events on
  `Phoenix.PubSub.broadcast(ServiceRadar.PubSub, "security_events", event)`
  so the Settings → Audit → Events LiveView can live-tail without an
  extra DB poll.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.SecurityEvent

  @default_max_queue 1_000
  @flush_interval :timer.seconds(1)
  @flush_batch_size 50

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records an event asynchronously. Returns `:ok` immediately even on
  overflow — on overflow the event is dropped and a telemetry counter
  is incremented.

  Required fields: `:kind` (atom in `SecurityEvent.kinds/0`).
  Optional fields: `:severity` (default `:info`), `:actor_id`, `:ip`,
  `:route`, `:details`, `:correlation_id`. `:occurred_at` defaults to
  `DateTime.utc_now/0` if omitted.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    payload = normalize(attrs)
    GenServer.cast(__MODULE__, {:record, payload})
  end

  @doc """
  Synchronous flush — exposed for tests so they can assert state after
  recording without sleeping.
  """
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc false
  def __default_max_queue__, do: @default_max_queue

  ## Server callbacks

  @impl true
  def init(opts) do
    max_queue =
      Keyword.get(opts, :max_queue) ||
        Application.get_env(:serviceradar_core, __MODULE__, [])
        |> Keyword.get(:max_queue, @default_max_queue)

    schedule_flush()

    {:ok,
     %{
       queue: :queue.new(),
       queue_size: 0,
       max_queue: max_queue,
       dropped: 0
     }}
  end

  @impl true
  def handle_cast({:record, _payload}, %{queue_size: size, max_queue: max} = state)
      when size >= max do
    :telemetry.execute([:serviceradar, :security, :events, :dropped], %{count: 1}, %{})
    {:noreply, %{state | dropped: state.dropped + 1}}
  end

  def handle_cast({:record, payload}, state) do
    {:noreply,
     %{state | queue: :queue.in(payload, state.queue), queue_size: state.queue_size + 1}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = drain(state, :infinity)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush()
    {:noreply, drain(state, @flush_batch_size)}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Internals

  defp drain(%{queue_size: 0} = state, _limit), do: state

  defp drain(state, limit) do
    {batch, remaining_queue, remaining_size} = take(state.queue, state.queue_size, limit)
    # Persistence happens off the GenServer so a slow DB never blocks
    # incoming records or the flush caller.
    case batch do
      [] -> :ok
      _ -> spawn(fn -> persist(batch) end)
    end
    %{state | queue: remaining_queue, queue_size: remaining_size}
  end

  defp take(queue, size, :infinity), do: take(queue, size, size)

  defp take(queue, size, limit) do
    n = min(size, limit)
    do_take(queue, n, [])
    |> case do
      {items, q_rest} -> {Enum.reverse(items), q_rest, size - n}
    end
  end

  defp do_take(queue, 0, acc), do: {acc, queue}

  defp do_take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> do_take(rest, n - 1, [item | acc])
      {:empty, rest} -> {acc, rest}
    end
  end

  defp persist([]), do: :ok

  defp persist(batch) do
    actor = SystemActor.system(:security_events)

    Enum.each(batch, fn payload ->
      try do
        case SecurityEvent
             |> Ash.Changeset.for_create(:create, payload)
             |> Ash.create(actor: actor) do
          {:ok, event} ->
            broadcast(event)

          {:error, error} ->
            Logger.warning(
              "SecurityEvents: persist failed: #{inspect(error)}; payload=#{inspect(payload)}"
            )
        end
      rescue
        e ->
          # DB unreachable or other infra failure — never let event
          # persistence crash the recorder.
          Logger.warning(
            "SecurityEvents: persist crashed: #{Exception.message(e)}; dropping event"
          )
      end
    end)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ServiceRadar.PubSub, "security_events", {:security_event, event})
  rescue
    _ -> :ok
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defp normalize(attrs) do
    attrs
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> Map.put_new(:severity, :info)
    |> Map.put_new(:details, %{})
  end
end
