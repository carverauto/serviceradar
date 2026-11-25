defmodule ServiceRadar.EventWriter.HorizonTopologyConsumer do
  @moduledoc """
  Coordinator-owned fail-open NATS JetStream pull consumer for Horizon external
  topology snapshots (`serviceradar.horizon.topology.snapshot`) and outage/BGP
  updates (`serviceradar.horizon.outages.>`, `serviceradar.horizon.bgp.>`), plus
  periodic TTL pruning of expired external topology edges.
  """

  use GenServer

  alias Gnat.Jetstream.API.Consumer, as: JetstreamConsumerApi
  alias Gnat.Jetstream.API.Util
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerSetup
  alias ServiceRadar.EventWriter.JetStreamAck
  alias ServiceRadar.EventWriter.Processors.HorizonTopology
  alias ServiceRadar.NATS.JetstreamConsumer
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.ExternalProjection

  require Logger

  @stream_name "horizon_topology"
  @durable_name "serviceradar-horizon-topology"
  @subjects [
    "serviceradar.horizon.topology.snapshot",
    "serviceradar.horizon.outages.>",
    "serviceradar.horizon.bgp.>"
  ]
  @stream_max_bytes 268_435_456
  @stream_max_age_ns 86_400_000_000_000
  @pull_batch_size 16
  @pull_expires_ns 2_000_000_000
  @idle_poll_ms 2_500
  @prune_interval_ms 300_000
  @max_deliver 5

  defstruct [
    :nats,
    :conn,
    :monitor,
    :pull_subject,
    :sub_sid,
    :prune_interval_ms,
    connected: false,
    connect_failures: 0,
    pull_inflight: 0
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec stream_subjects() :: [String.t()]
  def stream_subjects, do: @subjects

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Config.load()
    prune_ms = Keyword.get(opts, :prune_interval_ms, @prune_interval_ms)

    state = %__MODULE__{
      nats: Keyword.get(opts, :nats, config.nats),
      prune_interval_ms: prune_ms
    }

    send(self(), :connect)
    schedule_prune(prune_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case ConsumerSetup.open(state.nats) do
      {:ok, conn, monitor} ->
        case ensure_stream_and_consumer(conn) do
          :ok ->
            pull_subject = "_INBOX.horizon_topology.#{:erlang.unique_integer([:positive])}"
            {:ok, sid} = Gnat.sub(conn, self(), pull_subject)

            Logger.info("HorizonTopologyConsumer connected to JetStream stream #{@stream_name}")

            state = %{
              state
              | conn: conn,
                monitor: monitor,
                pull_subject: pull_subject,
                sub_sid: sid,
                connected: true,
                connect_failures: 0,
                pull_inflight: 0
            }

            {:noreply, request_batch(state)}

          {:error, reason} ->
            ConsumerSetup.close(conn)
            schedule_reconnect(state, reason)
        end

      {:error, reason} ->
        schedule_reconnect(state, reason)
    end
  end

  def handle_info(:poll, %{connected: true, pull_inflight: 0} = state) do
    {:noreply, request_batch(state)}
  end

  def handle_info(:poll, %{connected: true} = state) do
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:msg, %{body: "", topic: topic}}, %{pull_subject: topic} = state) do
    {:noreply, schedule_next_poll(%{state | pull_inflight: 0})}
  end

  def handle_info({:msg, %{topic: subject, body: body} = msg}, %{connected: true} = state) do
    reply_to = Map.get(msg, :reply_to)
    final? = final_delivery?(reply_to)

    case HorizonTopology.process_message(subject, body, final_delivery?: final?) do
      :ok ->
        ack(state.conn, reply_to, "+ACK")

      {:error, :transient} ->
        ack(state.conn, reply_to, "+NAK")
    end

    remaining = max(state.pull_inflight - 1, 0)
    next_state = %{state | pull_inflight: remaining}
    {:noreply, if(remaining == 0, do: request_batch(next_state), else: next_state)}
  end

  def handle_info(:prune_stale, state) do
    _ = prune_once()
    schedule_prune(state.prune_interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state) do
    schedule_reconnect(
      %{state | conn: nil, monitor: nil, connected: false, pull_inflight: 0},
      reason
    )
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    ConsumerSetup.close(state.conn)
  end

  defp ensure_stream_and_consumer(conn) do
    request = fn topic, body -> Util.request(conn, topic, body) end

    stream_payload = %{
      name: @stream_name,
      subjects: @subjects,
      retention: "limits",
      storage: "file",
      discard: "old",
      num_replicas: 1,
      max_bytes: @stream_max_bytes,
      max_age: @stream_max_age_ns
    }

    with :ok <- ensure_stream(request, stream_payload) do
      ensure_pull_consumer(request)
    end
  end

  defp ensure_stream(request, payload) do
    case JetstreamConsumer.stream_info(request, @stream_name) do
      {:ok, existing, stored} ->
        desired =
          existing
          |> Map.put("name", @stream_name)
          |> Map.put("subjects", @subjects)
          |> Map.put("max_bytes", @stream_max_bytes)
          |> Map.put("max_age", @stream_max_age_ns)

        JetstreamConsumer.update_stream_if_changed(
          request,
          @stream_name,
          existing,
          desired,
          stored
        )

      :absent ->
        case request.("$JS.API.STREAM.CREATE.#{@stream_name}", Jason.encode!(payload)) do
          {:ok, %{"error" => err}} -> {:error, err}
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_pull_consumer(request) do
    payload = %{
      stream_name: @stream_name,
      config: %{
        durable_name: @durable_name,
        ack_policy: "explicit",
        ack_wait: 120_000_000_000,
        max_deliver: @max_deliver,
        max_ack_pending: 256,
        deliver_policy: "all"
      }
    }

    topic = "$JS.API.CONSUMER.DURABLE.CREATE.#{@stream_name}.#{@durable_name}"

    case request.(topic, Jason.encode!(payload)) do
      {:ok, %{"error" => err}} -> {:error, err}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_batch(%{conn: conn, pull_subject: pull_subject} = state) when is_pid(conn) do
    _ =
      JetstreamConsumerApi.request_next_message(
        conn,
        @stream_name,
        @durable_name,
        pull_subject,
        nil,
        batch: @pull_batch_size,
        expires: @pull_expires_ns
      )

    schedule_poll()
    %{state | pull_inflight: @pull_batch_size}
  catch
    :exit, _reason ->
      schedule_poll()
      state
  end

  defp request_batch(state), do: state

  defp ack(conn, reply_to, signal) when is_pid(conn) and is_binary(reply_to) do
    Gnat.pub(conn, reply_to, signal)
  catch
    :exit, _ -> :ok
  end

  defp ack(_conn, _reply_to, _signal), do: :ok

  defp final_delivery?(reply_to) when is_binary(reply_to) do
    case JetStreamAck.parse(reply_to) do
      %{delivery_count: count} -> count >= @max_deliver
      _ -> false
    end
  end

  defp final_delivery?(_), do: false

  @doc false
  @spec prune_once(DateTime.t()) :: :ok
  def prune_once(now \\ DateTime.utc_now()) do
    now_iso = ExternalProjection.prune_timestamp(now)

    case TopologyGraph.prune_stale_external(now_iso) do
      {:ok, _count} -> :ok
      {:error, reason} -> Logger.debug("HorizonTopology stale prune skipped: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.debug("HorizonTopology stale prune raised: #{Exception.message(error)}")
      :ok
  end

  defp schedule_reconnect(state, reason) do
    failures = state.connect_failures + 1
    delay = ConsumerSetup.retry_delay(failures)

    Logger.warning(
      "HorizonTopologyConsumer connection failed: #{inspect(reason)}, retrying in #{delay}ms"
    )

    Process.send_after(self(), :connect, delay)
    {:noreply, %{state | conn: nil, monitor: nil, connected: false, connect_failures: failures}}
  end

  defp schedule_next_poll(state) do
    schedule_poll()
    state
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @idle_poll_ms)

  defp schedule_prune(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :prune_stale, interval_ms)
  end
end
