defmodule ServiceRadarWebNG.Notifications.FirehoseReplayConsumer do
  @moduledoc """
  Pulls one notification subscriber's durable JetStream cursor.

  The pull callback blocks until the owning Phoenix Channel has refreshed the
  subscriber's authority and either pushed or deduplicated the envelope. Only
  then does it return `:ack`. If the channel is gone, its permission was
  revoked, or it cannot answer in time, the record stays unacknowledged for the
  next authorized reconnect.
  """

  use Gnat.Jetstream.PullConsumer, restart: :temporary, shutdown: 5_000

  alias Gnat.Jetstream.API.Message

  require Logger

  @reply_timeout_ms 30_000
  # `handle_message/2` intentionally blocks while the browser confirms the
  # exact cursor. Gnat's defaults watchdog the pull request after ~5 seconds,
  # so its server-side window must exceed this callback wait.
  @request_expires_ns 60_000_000_000
  @idle_heartbeat_ns 30_000_000_000

  defguardp is_connection_ref(ref) when is_atom(ref) or is_pid(ref)

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(init) when is_map(init) do
    Gnat.Jetstream.PullConsumer.start_link(__MODULE__, init)
  end

  @impl true
  def init(%{
        channel_pid: channel_pid,
        connection_name: connection_name,
        consumer_name: consumer_name,
        stream_name: stream_name
      })
      when is_pid(channel_pid) and is_connection_ref(connection_name) and is_binary(consumer_name) and
             is_binary(stream_name) do
    state = %{
      channel_pid: channel_pid,
      reply_timeout_ms: @reply_timeout_ms
    }

    consumer_opts = [
      connection_name: connection_name,
      stream_name: stream_name,
      consumer_name: consumer_name,
      batch_size: 1,
      request_expires: @request_expires_ns,
      idle_heartbeat: @idle_heartbeat_ns
    ]

    {:ok, state, consumer_opts}
  end

  def init(_init), do: {:stop, :invalid_firehose_replay_consumer}

  @impl true
  def handle_message(%{body: body} = message, state) when is_binary(body) and is_map(state) do
    case Jason.decode(body) do
      {:ok, envelope} when is_map(envelope) ->
        await_channel(message, envelope, state)

      {:ok, _not_an_envelope} ->
        Logger.error("discarding non-object notification firehose record")
        {:term, state}

      {:error, reason} ->
        Logger.error("discarding undecodable notification firehose record: #{inspect(reason)}")
        {:term, state}
    end
  end

  def handle_message(_message, state) do
    Logger.error("discarding malformed notification firehose record")
    {:term, state}
  end

  defp await_channel(message, envelope, state) do
    reply_ref = make_ref()
    channel_pid = state.channel_pid
    monitor_ref = Process.monitor(channel_pid)

    send(
      channel_pid,
      {:firehose_replay, envelope, cursor_metadata(message), self(), reply_ref}
    )

    result =
      receive do
        {:firehose_replay_result, ^reply_ref, :ack} -> :ack
        {:firehose_replay_result, ^reply_ref, :leave_unacked} -> :noreply
        {:DOWN, ^monitor_ref, :process, ^channel_pid, _reason} -> :noreply
      after
        Map.get(state, :reply_timeout_ms, @reply_timeout_ms) -> :noreply
      end

    Process.demonitor(monitor_ref, [:flush])
    {result, state}
  end

  defp cursor_metadata(message) do
    case Message.metadata(message) do
      {:ok, metadata} ->
        %{
          consumer_sequence: metadata.consumer_seq,
          pending: metadata.num_pending,
          stream_sequence: metadata.stream_seq
        }

      {:error, _reason} ->
        %{}
    end
  end
end
