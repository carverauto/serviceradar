defmodule ServiceRadar.Observability.NatsIngestNotifier do
  @moduledoc """
  Lightweight NATS → PubSub bridge for observability live refresh.

  Subscribes to `logs.*.processed` and `flows.*.processed` via plain `Gnat.sub`
  (not JetStream PullConsumer — we don't need ack/delivery guarantees for notifications).

  On each message, debounces over a 2-second window and broadcasts once to
  `LogPubSub` / `FlowPubSub` with the accumulated count.
  """
  use GenServer
  require Logger

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Observability.{LogPubSub, FlowPubSub}

  @log_subject "logs.*.processed"
  @flow_subject "flows.*.processed"
  @debounce_ms 2_000
  @retry_interval_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :subscribe)
    {:ok, %{subscriptions: [], pending: %{}, timers: %{}}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    case Connection.get() do
      {:ok, conn} ->
        subs = subscribe_all(conn)
        {:noreply, %{state | subscriptions: subs}}

      {:error, reason} ->
        Logger.debug("NatsIngestNotifier: NATS not available (#{inspect(reason)}), retrying...")
        Process.send_after(self(), :subscribe, @retry_interval_ms)
        {:noreply, state}
    end
  end

  # NATS message received
  def handle_info({:msg, %{topic: topic}}, state) do
    category = categorize(topic)
    state = bump_pending(state, category)
    {:noreply, maybe_schedule_flush(state, category)}
  end

  # Debounce timer fires
  def handle_info({:flush, category}, state) do
    count = Map.get(state.pending, category, 0)
    if count > 0, do: broadcast(category, count)

    {:noreply, %{state |
      pending: Map.delete(state.pending, category),
      timers: Map.delete(state.timers, category)
    }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp subscribe_all(conn) do
    [@log_subject, @flow_subject]
    |> Enum.map(fn subject ->
      case Gnat.sub(conn, self(), subject) do
        {:ok, sid} ->
          Logger.info("NatsIngestNotifier: subscribed to #{subject}")
          {subject, sid}

        {:error, reason} ->
          Logger.error("NatsIngestNotifier: failed to subscribe to #{subject}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp categorize(topic) do
    cond do
      String.starts_with?(topic, "logs.") -> :logs
      String.starts_with?(topic, "flows.") -> :flows
      true -> :unknown
    end
  end

  defp bump_pending(state, category) do
    %{state | pending: Map.update(state.pending, category, 1, &(&1 + 1))}
  end

  defp maybe_schedule_flush(state, category) do
    if Map.has_key?(state.timers, category) do
      # Timer already running, just accumulate
      state
    else
      ref = Process.send_after(self(), {:flush, category}, @debounce_ms)
      %{state | timers: Map.put(state.timers, category, ref)}
    end
  end

  defp broadcast(:logs, count) do
    LogPubSub.broadcast_ingest(%{count: count})
  end

  defp broadcast(:flows, count) do
    FlowPubSub.broadcast_ingest(%{count: count})
  end

  defp broadcast(_category, _count), do: :ok
end
