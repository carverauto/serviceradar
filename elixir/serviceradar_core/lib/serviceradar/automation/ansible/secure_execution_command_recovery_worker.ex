defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandRecoveryWorker do
  @moduledoc "Periodic Oban backstop for hardened non-callback AWX executions."

  use Oban.Worker,
    queue: :ansible_pulse,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandRecovery
  alias ServiceRadar.SweepJobs.ObanSupport

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = SecureExecutionCommandRecovery.recover_once()
    :ok
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from(job in Oban.Job,
        where:
          job.worker == ^to_string(__MODULE__) and
            job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
