defmodule ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker do
  @moduledoc """
  Bounded evaluation on the existing supervised Oban alert worker pool.

  A job is a wake-up hint, not the accepted input. The inbox and receipts own
  ordering and durability. A running job does not consume the unique pending
  hint, so input arriving just as it finishes cannot strand the rule.
  """

  use Oban.Worker,
    queue: :alerts,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:rule_id],
      states: [:available, :scheduled, :retryable]
    ]

  alias ServiceRadar.Observability.StatefulAlertEngine.Owner
  alias ServiceRadar.SweepJobs.ObanSupport

  @quantum 16

  def enqueue(rule_id) do
    %{"rule_id" => rule_id} |> new() |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: 20_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"rule_id" => rule_id}}) do
    drain(rule_id, @quantum)
  end

  defp drain(_rule_id, 0), do: {:snooze, 1}

  defp drain(rule_id, remaining) do
    case Owner.advance(rule_id) do
      {:ok, {:processed, _disposition}} ->
        drain(rule_id, remaining - 1)

      {:ok, :empty} ->
        :ok

      {:ok, :busy} ->
        {:snooze, 1}

      {:ok, {:backoff, seconds}} ->
        {:snooze, seconds}

      {:error, {:evaluation_failed, work_id, reason}} ->
        Owner.defer(rule_id, work_id, reason)
        {:snooze, 2}

      {:error, _reason} ->
        {:snooze, 5}
    end
  end
end
