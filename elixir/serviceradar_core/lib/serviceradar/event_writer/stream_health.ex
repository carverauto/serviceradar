defmodule ServiceRadar.EventWriter.StreamHealth do
  @moduledoc """
  Reports EventWriter consumers whose JetStream stream could not be set up.

  A failed stream is retried on its own while every other consumer keeps
  running (see `ServiceRadar.EventWriter.Producer`), so a stream NATS refuses
  to place does not surface as a connection failure. This module makes it
  visible: telemetry on every failed attempt, and a health event on the
  transition to degraded and back to healthy.

  The health event is written off the producer's process so ingestion never
  waits on the database.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.HealthEvent

  require Logger

  @callback consumer_setup_failed(
              stream :: String.t(),
              reason :: term(),
              attempt :: pos_integer()
            ) ::
              :ok
  @callback consumer_setup_recovered(stream :: String.t(), attempts :: pos_integer()) :: :ok

  @entity_prefix "event-writer:"

  @doc "Reports a failed setup attempt for `stream`; the first attempt records a degraded health event."
  @spec consumer_setup_failed(String.t(), term(), pos_integer()) :: :ok
  def consumer_setup_failed(stream, reason, attempt) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :consumer_setup, :failed],
      %{count: 1, attempt: attempt},
      %{stream: stream, nats_error_code: nats_error_code(reason), reason: inspect(reason)}
    )

    if attempt == 1 do
      record(stream, :healthy, :degraded, :consumer_setup_failed, %{
        "nats_error_code" => nats_error_code(reason),
        "reason" => inspect(reason)
      })
    end

    :ok
  end

  @doc "Reports that `stream` set up after `attempts` failed attempts; records a healthy health event."
  @spec consumer_setup_recovered(String.t(), pos_integer()) :: :ok
  def consumer_setup_recovered(stream, attempts) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :consumer_setup, :recovered],
      %{count: 1, attempts: attempts},
      %{stream: stream}
    )

    record(stream, :degraded, :healthy, :recovery, %{"failed_attempts" => attempts})
    :ok
  end

  @doc """
  The NATS JetStream `err_code` in a setup failure reason, or nil.

  Reasons arrive as `{consumer_name, %{"err_code" => code}}` from
  `Producer.setup_jetstream_consumers/2`, or as the bare error map.
  """
  @spec nats_error_code(term()) :: integer() | nil
  def nats_error_code({_name, reason}), do: nats_error_code(reason)
  def nats_error_code(%{"err_code" => code}) when is_integer(code), do: code
  def nats_error_code(_reason), do: nil

  defp record(stream, old_state, new_state, reason, metadata) do
    attrs = %{
      entity_type: :core,
      entity_id: @entity_prefix <> stream,
      old_state: old_state,
      new_state: new_state,
      reason: reason,
      node: to_string(node()),
      metadata: metadata
    }

    Task.start(fn ->
      case HealthEvent.record(attrs, actor: SystemActor.system(:event_writer_stream_health)) do
        {:ok, _event} ->
          :ok

        {:error, error} ->
          Logger.warning("EventWriter could not record stream health event",
            stream: stream,
            new_state: new_state,
            reason: inspect(error)
          )
      end
    end)

    :ok
  end
end
