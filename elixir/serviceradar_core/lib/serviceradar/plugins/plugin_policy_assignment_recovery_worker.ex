defmodule ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryWorker do
  @moduledoc """
  Restricted Oban worker for one durable policy-assignment recovery request.

  Its job payload intentionally contains only `request_id`. All agent, policy,
  credential, partition, and principal information is reloaded from the
  immutable request and current authoritative sources by the executor.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:request_id],
      states: :incomplete
    ]

  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Executor
  alias ServiceRadar.SweepJobs.ObanSupport

  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(request_id) when is_binary(request_id) do
    if ObanSupport.available?() do
      %{"request_id" => request_id}
      |> new()
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  def enqueue(_request_id), do: {:error, :invalid_recovery_request_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request_id}}) when is_binary(request_id) do
    case Executor.execute(request_id) do
      {:ok, _terminal_outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:error, :invalid_recovery_request_job}
end
