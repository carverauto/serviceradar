defmodule ServiceRadar.Edge.AgentCommandCleanupWorker do
  @moduledoc """
  Worker that expires stale agent commands and trims command history.

  - Marks commands as expired when their TTL has elapsed.
  - Deletes command history older than the retention window (default: 2 days).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_retention_days 2
  @default_reschedule_seconds 60

  @doc """
  Schedules agent command cleanup if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    retention_days = Keyword.get(config, :retention_days, @default_retention_days)
    retention_cutoff = DateTime.add(now, -retention_days * 86_400, :second)

    expire_stale_commands(now)
    delete_old_commands(retention_cutoff)
    schedule_next_cleanup()

    :ok
  end

  defp schedule_next_cleanup do
    ObanSupport.safe_insert(new(%{}, schedule_in: @default_reschedule_seconds))
    :ok
  end

  defp expire_stale_commands(now) do
    actor = SystemActor.system(:agent_command_expire)

    query =
      Ash.Query.filter(
        AgentCommand,
        expr(
          status in [:queued, :sent, :acknowledged, :running] and not is_nil(expires_at) and
            expires_at <= ^now
        )
      )

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: results}} ->
        Enum.each(results, &expire_command(&1, actor))

      {:ok, results} when is_list(results) ->
        Enum.each(results, &expire_command(&1, actor))

      {:error, reason} ->
        Logger.warning("AgentCommandCleanupWorker: failed to read expirable commands",
          reason: inspect(reason)
        )
    end
  end

  defp expire_command(command, actor) do
    case AgentCommand.expire(command, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandCleanupWorker: failed to expire command",
          command_id: command.id,
          reason: inspect(reason)
        )
    end
  end

  defp delete_old_commands(cutoff) do
    actor = SystemActor.system(:agent_command_cleanup)

    query = Ash.Query.filter(AgentCommand, expr(inserted_at < ^cutoff))

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: results}} ->
        Enum.each(results, &destroy_command(&1, actor))

      {:ok, results} when is_list(results) ->
        Enum.each(results, &destroy_command(&1, actor))

      {:error, reason} ->
        Logger.warning("AgentCommandCleanupWorker: failed to read old commands",
          reason: inspect(reason)
        )
    end
  end

  defp destroy_command(command, actor) do
    case Ash.destroy(command, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandCleanupWorker: failed to delete command",
          command_id: command.id,
          reason: inspect(reason)
        )
    end
  end
end
