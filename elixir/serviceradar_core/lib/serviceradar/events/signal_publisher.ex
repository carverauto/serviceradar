defmodule ServiceRadar.Events.SignalPublisher do
  @moduledoc """
  Publishes a core-produced analytics signal to JetStream on its
  `signals.analytics.*` subject, where EventWriter's `AnalyticsSignals`
  processor maps and stores it like a signal from any other source.

  Durable (`ServiceRadar.NATS.DurablePublish`): a failed publish is retried
  from an Oban job, and from inside a transaction the signal is queued with it.
  Each publish carries its own message id. A signal's `event_id` is not used:
  lifecycle transitions of one finding share it, and the stream's duplicate
  window would drop a quick open-then-resolve. `AnalyticsSignals` stores
  idempotently on the event id instead.
  """

  alias ServiceRadar.NATS.DurablePublish

  @spec publish(String.t(), map()) :: :ok | {:error, term()}
  def publish("signals.analytics." <> _ = subject, payload) when is_map(payload) do
    case DurablePublish.publish(subject, Jason.encode!(payload), msg_id: Ash.UUID.generate()) do
      :ok -> :ok
      {:ok, :enqueued} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
