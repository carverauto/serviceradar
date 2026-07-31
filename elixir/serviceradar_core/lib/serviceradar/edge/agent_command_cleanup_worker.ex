defmodule ServiceRadar.Edge.AgentCommandCleanupWorker do
  @moduledoc """
  Worker that expires stale agent commands and trims command history.

  - Marks commands as expired when their TTL has elapsed.
  - Deletes terminal-state command history older than the retention window
    (default: 2 days) in a single set-based, batched DELETE.

  ## Why the rewrite (live demo evidence, cnpg-23 primary, 2026-06-17)

  `platform.agent_commands` had grown to 97k rows / 125 MB with 99.7% of rows
  older than a day, and the retention scan
  (`SELECT ...23 cols... WHERE inserted_at::timestamp < $1`) was the #2 hot path
  on the demo DB: ~18s mean, ~15% of total exec time. Three compounding causes,
  all fixed here plus the companion migration:

    1. No index on `inserted_at` -> every run seq-scanned the whole table. The
       companion migration adds a partial `inserted_at` index over terminal rows.
    2. The filter compared the timestamptz `inserted_at` column against a bare
       `DateTime` cutoff, so ash_sql coerced both operands to a common type and
       cast the column side to `::timestamp`, which defeated any index. We now
       bind the cutoff as `type(^cutoff, :utc_datetime_usec)` (matching the
       column) so the column is compared without a cast and the index is usable.
    3. The old path `Ash.read`-loaded every stale row (incl. payload /
       result_payload / progress_payload JSONB) into the BEAM and issued N
       single-row `Ash.destroy`s, so the backlog never cleared. We now issue a
       single batched `Ash.bulk_destroy` (set-based DELETE, no JSONB fetched).

  Retention only ever deletes **terminal** rows (completed / failed / expired /
  canceled / offline). In-flight rows (queued / sent / acknowledged / running)
  are never deleted by age -- they are transitioned to `:expired` first by the
  TTL sweep (`expire_stale_commands/1`) and only then become eligible.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @terminal_states [:completed, :failed, :expired, :canceled, :offline]

  @default_retention_days 2
  @default_reschedule_seconds 3_600
  @min_reschedule_seconds 60

  # Cap rows deleted per sweep so a single DELETE never holds a long lock on the
  # write-hot table. The worker self-reschedules, so any residual backlog is
  # drained on subsequent runs.
  @delete_batch_size 5_000
  @max_delete_batches 50

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
    retention_cutoff = DateTime.add(now, -retention_days() * 86_400, :second)

    expire_stale_commands(now)
    delete_old_commands(retention_cutoff)
    schedule_next_cleanup()

    :ok
  end

  @doc false
  @spec retention_days() :: pos_integer()
  def retention_days do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
    |> normalize_positive(@default_retention_days)
  end

  @doc false
  @spec reschedule_seconds() :: pos_integer()
  def reschedule_seconds do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:reschedule_seconds, @default_reschedule_seconds)
    |> normalize_positive(@default_reschedule_seconds)
    |> max(@min_reschedule_seconds)
  end

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive(_value, default), do: default

  defp schedule_next_cleanup do
    ObanSupport.safe_insert(
      SelfScheduling.successor_changeset(__MODULE__, %{}, reschedule_seconds())
    )

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
      {:ok, expired} ->
        AgentReleaseManager.handle_command_expired(expired, actor: actor)
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandCleanupWorker: failed to expire command",
          command_id: command.id,
          reason: inspect(reason)
        )
    end
  end

  # Deletes terminal-state command rows older than `cutoff` using a set-based,
  # batched DELETE rather than reading every stale row (incl. JSONB payloads)
  # into the BEAM and destroying it one-by-one.
  #
  # The filter guards on `@terminal_states` so in-flight commands are NEVER
  # deleted by age. Only `:id` is selected (no JSONB), and
  # `type(^cutoff, :utc_datetime_usec)` pins the bound to the column type
  # (timestamptz) so AshPostgres compares `inserted_at` directly without the
  # `::timestamp` cast that previously defeated the index.
  defp delete_old_commands(cutoff) do
    actor = SystemActor.system(:agent_command_cleanup)
    delete_old_commands_batches(cutoff, actor, 0, 0)
  end

  defp delete_old_commands_batches(_cutoff, _actor, batches, total)
       when batches >= @max_delete_batches do
    Logger.warning(
      "AgentCommandCleanupWorker: hit max delete batches, deferring remainder to next run",
      deleted: total,
      batches: batches
    )

    :ok
  end

  defp delete_old_commands_batches(cutoff, actor, batches, total) do
    query =
      AgentCommand
      |> Ash.Query.filter(
        expr(
          status in ^@terminal_states and
            inserted_at < type(^cutoff, :utc_datetime_usec)
        )
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(@delete_batch_size)

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: results}} ->
        process_delete_batch(results, cutoff, actor, batches, total)

      {:ok, results} when is_list(results) ->
        process_delete_batch(results, cutoff, actor, batches, total)

      {:error, reason} ->
        Logger.warning("AgentCommandCleanupWorker: failed to read old commands",
          reason: inspect(reason)
        )

        maybe_log_deleted(total)
    end
  end

  defp process_delete_batch([], _cutoff, _actor, _batches, total), do: maybe_log_deleted(total)

  defp process_delete_batch(results, cutoff, actor, batches, total) do
    count = length(results)
    destroy_batch(results, actor)
    total = total + count

    if count >= @delete_batch_size do
      delete_old_commands_batches(cutoff, actor, batches + 1, total)
    else
      maybe_log_deleted(total)
    end
  end

  defp destroy_batch(records, actor) do
    result =
      Ash.bulk_destroy(records, :destroy, %{},
        actor: actor,
        return_records?: false,
        return_errors?: true
      )

    if match?(%Ash.BulkResult{status: :error}, result) do
      Logger.warning("AgentCommandCleanupWorker: bulk destroy failed", reason: inspect(result))
    end

    :ok
  end

  defp maybe_log_deleted(0), do: :ok

  defp maybe_log_deleted(total) do
    Logger.info("AgentCommandCleanupWorker: pruned terminal commands", deleted: total)
    :ok
  end
end
