defmodule ServiceRadar.Automation.Ansible.LifecycleSeedWorker do
  @moduledoc """
  Periodic boot/backstop worker that seeds AWX/AAP controller lifecycle jobs and
  inventory-sync plugin assignments.
  """

  use Oban.Worker,
    queue: :ansible_catalog,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Automation.Ansible.Lifecycle
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

  # Cadence is driven entirely by LifecycleScheduler (an ObanEnsureScheduled
  # ticker): it re-enqueues this job once the previous run completes. A
  # perform-time self-reschedule was removed — the job's `unique` window
  # includes `:executing`, so a self-insert deduped against the currently
  # running job and never landed (the reschedule was silently dead).
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Lifecycle.seed_all()
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
