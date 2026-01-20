defmodule ServiceRadar.Jobs.JobScheduleSeeder do
  @moduledoc """
  Seeds default job schedules on startup.

  The DB connection's search_path determines which schema the schedules
  are seeded into.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.JobSchedule

  @seed_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :seed, @seed_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:seed, state) do
    seed_all()
    {:noreply, state}
  end

  def seed_all do
    if repo_enabled?() do
      actor = SystemActor.system(:job_schedule_seeder)
      opts = [actor: actor]

      default_schedules()
      |> Enum.each(&ensure_schedule(&1, opts))
    end
  end

  defp default_schedules do
    [
      %{
        job_key: JobSchedule.identity_reconciliation_job_key(),
        cron: JobSchedule.identity_reconciliation_cron(),
        timezone: "Etc/UTC",
        args: %{},
        enabled: true,
        unique_period_seconds: 300
      }
    ]
  end

  defp ensure_schedule(attrs, opts) do
    case JobSchedule.get_by_job_key(attrs.job_key, opts) do
      {:ok, %JobSchedule{}} ->
        :ok

      {:ok, nil} ->
        create_schedule(attrs, opts)

      {:error, reason} ->
        if not_found?(reason) do
          create_schedule(attrs, opts)
        else
          Logger.warning("Failed to check job schedule #{attrs.job_key}: #{inspect(reason)}")
        end

      other ->
        Logger.warning("Failed to check job schedule #{attrs.job_key}: #{inspect(other)}")
    end
  end

  defp create_schedule(attrs, opts) do
    changeset = Ash.Changeset.for_create(JobSchedule, :create, attrs, opts)

    case Ash.create(changeset) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to seed job schedule #{attrs.job_key}: #{inspect(reason)}")
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end
end
