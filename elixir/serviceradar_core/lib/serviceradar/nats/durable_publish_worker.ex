defmodule ServiceRadar.NATS.DurablePublishWorker do
  @moduledoc """
  Retries a JetStream publish that `ServiceRadar.NATS.DurablePublish` could
  not complete, until a stream acknowledges it.

  The job is unique on the message id, so a producer that fails to publish the
  same message twice stores one retry. The publish carries the same
  `Nats-Msg-Id`, and consumers store idempotently on it, so a retry that races
  a late original acknowledgement stores nothing twice.
  """

  use Oban.Worker,
    queue: :events,
    # With the backoff below (doubling from 2 s, capped at 30 min) 60 attempts
    # span about 24 hours -- the EVENTS stream's own retention -- so an outage
    # that long is ridden out, and a message the stream will never accept ends
    # as a discarded job rather than retrying forever.
    max_attempts: 60,
    unique: [period: :infinity, keys: [:msg_id], states: :incomplete]

  alias ServiceRadar.NATS.DurablePublish

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subject" => subject, "body" => body, "msg_id" => msg_id} = args}) do
    case DurablePublish.publisher().publish(subject, body, msg_id: msg_id) do
      :ok ->
        DurablePublish.run_on_published(Map.get(args, "on_published"), body)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # 2, 4, 8, ... seconds, capped at 30 minutes.
    min(trunc(:math.pow(2, attempt)), 1_800)
  end
end
