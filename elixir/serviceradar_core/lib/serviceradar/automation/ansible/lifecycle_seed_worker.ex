defmodule ServiceRadar.Automation.Ansible.LifecycleSeedWorker do
  @moduledoc """
  Periodic boot/backstop worker that seeds AWX/AAP controller lifecycle jobs and
  inventory-sync plugin assignments.
  """

  use Oban.Worker,
    queue: :ansible_catalog,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Automation.Ansible.Lifecycle
  alias ServiceRadar.SweepJobs.ObanSupport

  @default_reschedule_seconds 300
  @min_reschedule_seconds 60

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
    Lifecycle.seed_all()
    schedule_next()
    :ok
  end

  defp schedule_next do
    seconds =
      :serviceradar_core
      |> Application.get_env(:awx_lifecycle_seed_interval_seconds, @default_reschedule_seconds)
      |> max(@min_reschedule_seconds)

    _ = %{} |> new(schedule_in: seconds) |> ObanSupport.safe_insert()
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
