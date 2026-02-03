defmodule ServiceRadar.Observability.LogPromotionConsumer do
  @moduledoc """
  Subscribes to processed log subjects and promotes matching logs to events.
  """

  use GenServer

  require Logger

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Observability.{LogPromotion, LogPromotionParser}

  @subjects ["logs.*.processed"]
  @reconnect_delay :timer.seconds(5)

  defstruct [
    :conn,
    :subscriptions,
    :last_error,
    :processed_count,
    :promoted_count
  ]

  @type state :: %__MODULE__{
          conn: pid() | nil,
          subscriptions: list(),
          last_error: term() | nil,
          processed_count: non_neg_integer(),
          promoted_count: non_neg_integer()
        }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:serviceradar_core, :log_promotion_consumer_enabled, false)
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{enabled: enabled?(), running: false, connected: false, last_error: :not_running}

      _pid ->
        GenServer.call(__MODULE__, :status)
    end
  rescue
    _ -> %{enabled: enabled?(), running: false, connected: false, last_error: :unknown}
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      conn: nil,
      subscriptions: [],
      last_error: nil,
      processed_count: 0,
      promoted_count: 0
    }

    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: enabled?(),
       running: true,
       connected: is_pid(state.conn) and Process.alive?(state.conn),
       last_error: state.last_error,
       processed_count: state.processed_count,
       promoted_count: state.promoted_count
     }, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case Connection.get() do
      {:ok, conn} ->
        Process.monitor(conn)

        subscriptions = subscribe(conn)

        Logger.info("Log promotion consumer connected", subjects: @subjects)

        {:noreply, %{state | conn: conn, subscriptions: subscriptions, last_error: nil}}

      {:error, reason} ->
        Logger.warning("Log promotion consumer failed to connect to NATS",
          reason: inspect(reason)
        )

        Process.send_after(self(), :connect, @reconnect_delay)
        {:noreply, %{state | last_error: reason}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{conn: conn} = state)
      when pid == conn do
    Logger.warning("Log promotion consumer NATS connection lost", reason: inspect(reason))
    Process.send_after(self(), :connect, @reconnect_delay)
    {:noreply, %{state | conn: nil, subscriptions: [], last_error: reason}}
  end

  @impl true
  def handle_info({:msg, %{body: body, topic: subject, reply_to: reply_to}}, state) do
    received_at = DateTime.utc_now()
    logs = LogPromotionParser.parse_payload(body, subject, received_at)

    {promoted, state} =
      case logs do
        [] ->
          {0, state}

        _ ->
          {:ok, count} = LogPromotion.promote(logs)

          :telemetry.execute(
            [:serviceradar, :log_promotion, :consumer, :processed],
            %{logs: length(logs), events: count},
            %{subject: subject}
          )

          {count, %{state | promoted_count: state.promoted_count + count}}
      end

    state = %{state | processed_count: state.processed_count + length(logs)}

    maybe_ack(state.conn, reply_to, promoted >= 0)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp subscribe(conn) do
    Enum.flat_map(@subjects, fn subject ->
      case Gnat.sub(conn, self(), subject) do
        {:ok, sid} ->
          [{subject, sid}]

        {:error, reason} ->
          Logger.error("Log promotion consumer failed to subscribe",
            subject: subject,
            reason: inspect(reason)
          )

          []
      end
    end)
  end

  defp maybe_ack(conn, reply_to, _ok)
       when not is_pid(conn) or not is_binary(reply_to) or reply_to == "" do
    :ok
  end

  defp maybe_ack(conn, reply_to, true) do
    Gnat.pub(conn, reply_to, "+ACK")
  end

  defp maybe_ack(conn, reply_to, false) do
    Gnat.pub(conn, reply_to, "-NAK")
  end
end
