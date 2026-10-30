defmodule ServiceRadar.Edge.ManagedCertificateLifecycleWorker do
  @moduledoc "Resumes a durable certificate operation after delivery delays or node restart."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:operation_id], states: :incomplete]

  alias ServiceRadar.Edge.ManagedCertificateLifecycle
  alias ServiceRadar.SweepJobs.ObanSupport

  def enqueue(operation_id) do
    %{"operation_id" => operation_id} |> new() |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case ManagedCertificateLifecycle.reconcile(id) do
      {:ok, %{status: status}} when status in [:preparing, :issuing, :installing] ->
        {:snooze, 1}

      {:ok, _} ->
        :ok

      {:error, reason}
      when reason in [:operation_superseded, :component_unavailable, :not_found] ->
        :ok

      result ->
        result
    end
  end
end
