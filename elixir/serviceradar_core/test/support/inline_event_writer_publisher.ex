defmodule ServiceRadar.TestSupport.InlineEventWriterPublisher do
  @moduledoc """
  Test stand-in for `ServiceRadar.NATS.JetStreamPublish`.

  Hands each published message to the EventWriter processor that consumes its
  subject, as the pipeline would after the JetStream hop, so a test observes
  the stored rows the production path produces. The message carries the same
  `Nats-Msg-Id` header, so processors derive the same stable ids.

  It keeps the production contract between the two sides: once published, a
  message is the pipeline's to deliver, so `publish/3` returns `:ok`, and a
  batch the processor fails is delivered again, up to the stream's
  `max_deliver`, exactly as JetStream redelivers it.
  """

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.Logs

  require Logger

  @max_deliver 5

  @spec publish(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(subject, body, opts) do
    with {:ok, processor} <- processor_for(subject) do
      message = %{
        data: body,
        metadata: %{
          subject: subject,
          headers: headers(opts),
          received_at: DateTime.utc_now()
        }
      }

      deliver(processor, message, 1)
    end
  end

  defp deliver(processor, message, delivery) do
    case processor.process_batch([message]) do
      {:ok, _count} ->
        :ok

      {:error, reason} when delivery < @max_deliver ->
        Logger.debug("Inline EventWriter redelivery", reason: inspect(reason), delivery: delivery)
        deliver(processor, message, delivery + 1)

      {:error, reason} ->
        Logger.warning(
          "Inline EventWriter gave up after max_deliver on #{message.metadata.subject}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp processor_for("events." <> _), do: {:ok, Events}
  defp processor_for("logs." <> _), do: {:ok, Logs}
  defp processor_for("signals.analytics." <> _), do: {:ok, AnalyticsSignals}
  defp processor_for(subject), do: {:error, {:no_consumer, subject}}

  defp headers(opts) do
    case Keyword.get(opts, :msg_id) do
      id when is_binary(id) and id != "" -> [{"Nats-Msg-Id", id}]
      _ -> []
    end
  end
end
