defmodule ServiceRadar.SweepJobs.SweepDeclaredTargetsWorker do
  @moduledoc """
  Records which device targets each sweep group's target query declares, in
  `platform.sweep_group_declared_targets`, so `platform.device_sweep_overlap`
  can compare declared targets with observed coverage.

  Compiled sweep configs are cached in memory per agent and never persisted,
  so the declaration has to be recorded on its own. It is recorded once per
  group, not once per agent: a group's device targets do not depend on which
  agent sweeps it, and the view derives the agent from the group's
  `agent_ids`. Static targets are not recorded; the view reads them from
  `sweep_groups.static_targets`.

  ## Resolution

  Targets are resolved with `SweepCompiler.declared_device_targets/2`, so
  normalization, IP de-duplication and the shared target query cache are the
  same as for the configs agents receive.

  ## Failures keep the last good declaration

  A group whose query fails, or fails part-way through paging, keeps the rows
  it already has. Replacing them with nothing would turn a transient SRQL
  error into "this group declares no targets", which the overlap view would
  then report as every device being observed-but-not-declared. A query that
  succeeds with zero rows does clear the group's rows.

  ## Scheduling

  An args-less run refreshes every group and reschedules itself every five
  minutes; device membership of a query-based group has no change
  notification, so the cadence bounds how stale a declaration can be. A run
  with a `"sweep_group_id"` argument refreshes one group and does not
  reschedule; `ScheduleSweepMonitor` enqueues one when a group is created,
  updated or enabled, so a new or edited group does not wait for the cycle.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :args], states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.SweepJobs.SweepGroup

  require Logger

  @reschedule_interval_seconds 300

  # A job carrying this arg refreshes one group and is not part of the chain.
  @one_off_arg "sweep_group_id"

  @type pair :: {String.t(), String.t() | nil}
  @type plan :: %{upsert: [pair()], delete: [String.t()]}

  @doc """
  Schedules the periodic refresh if not already scheduled.

  Duplicate chain jobs are cancelled down to one, as for the other sweep
  maintenance workers; a one-off `"sweep_group_id"` run is not part of the
  chain, so it is neither counted nor cancelled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case ObanSupport.incomplete_chain_job_count(__MODULE__, @one_off_arg) do
        0 ->
          %{} |> new() |> ObanSupport.safe_insert()

        1 ->
          {:ok, :already_scheduled}

        _duplicates ->
          ObanSupport.cancel_duplicate_pending_jobs(__MODULE__, @one_off_arg)
          {:ok, :already_scheduled}
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @doc """
  Enqueues a one-off refresh of a single group.
  """
  @spec enqueue_group(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_group(sweep_group_id) do
    if ObanSupport.available?() do
      %{@one_off_arg => sweep_group_id} |> new() |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{@one_off_arg => sweep_group_id}}) do
    refresh_group(sweep_group_id)
  end

  def perform(%Oban.Job{}) do
    result = refresh_all()
    schedule_next_refresh()
    result
  end

  @doc """
  Refreshes the recorded declaration of every group, and drops the rows of
  groups that are disabled or no longer have a target query.
  """
  @spec refresh_all(keyword()) :: :ok | {:error, term()}
  def refresh_all(opts \\ []) do
    actor = SystemActor.system(:sweep_declared_targets)

    case Ash.read(SweepGroup, actor: actor) do
      {:ok, groups} ->
        Enum.each(groups, &refresh(&1, opts))

      {:error, reason} ->
        Logger.error("SweepDeclaredTargets: failed to load sweep groups: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refreshes the recorded declaration of one group. A group that no longer
  exists has already lost its rows through the foreign key cascade.
  """
  @spec refresh_group(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def refresh_group(sweep_group_id, opts \\ []) do
    actor = SystemActor.system(:sweep_declared_targets)

    case Ash.get(SweepGroup, sweep_group_id, actor: actor, not_found_error?: false) do
      {:ok, nil} ->
        :ok

      {:ok, group} ->
        refresh(group, opts)

      {:error, reason} ->
        Logger.error(
          "SweepDeclaredTargets: failed to load sweep group #{inspect(sweep_group_id)}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc false
  # The rows to write so a group's recorded declaration equals `declared`,
  # touching only what changed: unchanged rows keep their resolved_at.
  @spec plan_changes([pair()], [pair()]) :: plan()
  def plan_changes(current, declared) do
    current_map = Map.new(current)
    declared_map = Map.new(declared)

    upsert =
      declared_map
      |> Enum.reject(fn {target, uid} ->
        Map.has_key?(current_map, target) and Map.fetch!(current_map, target) == uid
      end)
      |> Enum.sort()

    delete =
      current_map
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(declared_map, &1))
      |> Enum.sort()

    %{upsert: upsert, delete: delete}
  end

  defp refresh(%SweepGroup{enabled: true} = group, opts) do
    case SweepCompiler.declared_device_targets(group, opts) do
      {:ok, declared} ->
        write(group.id, declared)

      {:error, reason} ->
        Logger.warning(
          "SweepDeclaredTargets: keeping the last recorded targets for group " <>
            "#{inspect(group.id)}; its target query did not resolve: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp refresh(%SweepGroup{} = group, _opts), do: write(group.id, [])

  defp write(sweep_group_id, declared) do
    with {:ok, current} <- current_rows(sweep_group_id) do
      case plan_changes(current, declared) do
        %{upsert: [], delete: []} -> :ok
        plan -> apply_plan(sweep_group_id, plan)
      end
    end
  end

  defp current_rows(sweep_group_id) do
    case Repo.query(
           """
           SELECT target, device_uid
           FROM platform.sweep_group_declared_targets
           WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid)
           """,
           [sweep_group_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [target, uid] -> {target, uid} end)}
      {:error, reason} -> log_write_error(sweep_group_id, reason)
    end
  end

  defp apply_plan(sweep_group_id, %{upsert: upsert, delete: delete}) do
    {targets, uids} = Enum.unzip(upsert)

    result =
      Repo.transaction(fn ->
        Repo.query!(
          """
          DELETE FROM platform.sweep_group_declared_targets
          WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid) AND target = ANY(CAST($2 AS text[]))
          """,
          [sweep_group_id, delete]
        )

        Repo.query!(
          """
          INSERT INTO platform.sweep_group_declared_targets
            (sweep_group_id, target, device_uid, resolved_at)
          SELECT CAST(CAST($1 AS text) AS uuid), t.target, t.device_uid, now()
          FROM unnest(CAST($2 AS text[]), CAST($3 AS text[])) AS t(target, device_uid)
          ON CONFLICT (sweep_group_id, target) DO UPDATE
            SET device_uid = EXCLUDED.device_uid, resolved_at = EXCLUDED.resolved_at
          """,
          [sweep_group_id, targets, uids]
        )
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> log_write_error(sweep_group_id, reason)
    end
  rescue
    error -> log_write_error(sweep_group_id, error)
  end

  defp log_write_error(sweep_group_id, reason) do
    Logger.error(
      "SweepDeclaredTargets: failed to record targets for group #{inspect(sweep_group_id)}: " <>
        inspect(reason)
    )

    {:error, reason}
  end

  defp schedule_next_refresh do
    case ObanSupport.safe_insert(
           SelfScheduling.successor_changeset(__MODULE__, %{}, @reschedule_interval_seconds)
         ) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Sweep declared-targets reschedule deferred", reason: inspect(reason))
        :ok
    end
  end
end
