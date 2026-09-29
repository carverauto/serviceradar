defmodule ServiceRadar.SweepJobs.DeclaredTargets do
  @moduledoc """
  Persists the declared target relation for one sweep group.

  `platform.sweep_group_declared_targets` is the declared side of the
  `device_sweep_overlap` view (issue #4963): one row per (sweep group,
  target). See `SweepGroupDeclaredTarget` for the row semantics.

  Two paths write it:

    * `refresh/1`, from `ServiceRadar.SweepJobs.DeclaredTargetsNotifier`,
      when a group's targeting is edited;
    * `record_compiled/2`, from `SweepCompiler.compile/3`, with the targets a
      group was just compiled into an agent's config. A query-based group's
      device targets change with inventory, not only with edits, so this is
      what keeps SRQL-declared rows current. It records exactly what agents
      received.

  Both go through one writer. A group whose target query did not fully
  resolve is never written, so a transient SRQL failure keeps the previous
  declaration instead of pruning it to "declares no devices". A write runs in
  one transaction behind a per-group `pg_try_advisory_xact_lock`: a writer
  that finds the lock taken skips, because another writer is recording the
  same group right now. A set equal to the stored rows is not rewritten, so
  `declared_at` only moves when the declaration changes, and the compile path
  also keeps a digest of the last recorded set under the `:sweep` config type
  to skip the database entirely.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupDeclaredTarget

  require Ash.Query
  require Logger

  @digest_partition "__sweep_declared_targets__"

  # Two-key advisory lock namespace, so these locks cannot collide with a
  # single-key advisory lock taken elsewhere.
  @lock_class "sweep_group_declared_targets"

  @doc """
  Replaces the persisted declared-target rows for `group`, resolving its
  targets now.

  Returns `{:ok, row_count}`, `{:error, :target_query_unresolved}` when the
  group's target query did not fully resolve (the previous rows are kept),
  `{:error, :busy}` when another writer holds the group, or `{:error, reason}`.
  """
  @spec refresh(SweepGroup.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def refresh(%SweepGroup{} = group) do
    case SweepCompiler.declared_targets(group) do
      %{device: :unresolved} ->
        {:error, :target_query_unresolved}

      %{static: static, device: device} ->
        write(group.id, build_rows(group.id, static, device))
    end
  end

  @doc """
  Records the declared targets of compiled sweep groups, skipping the groups
  in `unresolved` and every group whose set is unchanged since it was last
  recorded. Never raises.
  """
  @spec record_compiled([map()], MapSet.t()) :: :ok
  def record_compiled(compiled_groups, unresolved) do
    for %{"id" => group_id} = compiled <- compiled_groups,
        not MapSet.member?(unresolved, group_id) do
      device = SweepCompiler.declared_device_targets(compiled["device_targets"] || [])
      record_if_changed(group_id, build_rows(group_id, compiled["targets"] || [], device))
    end

    :ok
  end

  defp record_if_changed(group_id, rows) do
    digest = rows |> row_keys() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))
    scope = {:sweep_declared_digest, group_id}

    case ConfigCache.get(:sweep, @digest_partition, nil, scope) do
      {:ok, %{digest: ^digest}} ->
        :ok

      _ ->
        case write(group_id, rows) do
          {:ok, _count} ->
            ConfigCache.put(:sweep, @digest_partition, nil, %{digest: digest}, scope)

          {:error, :busy} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "DeclaredTargets: recording compiled targets failed for group " <>
                "#{inspect(group_id)}: #{inspect(reason)}"
            )
        end
    end
  rescue
    error ->
      Logger.warning(
        "DeclaredTargets: recording compiled targets raised for group " <>
          "#{inspect(group_id)}: " <> Exception.message(error)
      )
  end

  defp build_rows(group_id, static, device) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    declared =
      Map.new(static, fn target -> {target, %{device_uid: nil, source: :static}} end)

    # A target that is both static and SRQL-resolved is one row carrying the
    # device uid, matching the dedup the compiled-config view arms performed
    # with max(declared_device_uid).
    declared =
      Enum.reduce(device, declared, fn %{target: target, device_uid: device_uid}, acc ->
        Map.put(acc, target, %{device_uid: device_uid, source: :srql})
      end)

    for {target, %{device_uid: device_uid, source: source}} <- Enum.sort(declared) do
      %{
        sweep_group_id: group_id,
        target: target,
        device_uid: device_uid,
        source: source,
        declared_at: now
      }
    end
  end

  defp row_keys(rows) do
    rows
    |> Enum.map(&{&1.target, &1.device_uid, to_string(&1.source)})
    |> Enum.sort()
  end

  # Upsert first, then prune rows the group no longer declares, in one
  # transaction: a failure leaves the previous snapshot visible rather than an
  # empty or half-written declared side.
  defp write(group_id, rows) do
    actor = SystemActor.system(:sweep_compiler)

    Repo.transaction(fn ->
      cond do
        not lock_group(group_id) ->
          Repo.rollback(:busy)

        stored_keys(group_id) == row_keys(rows) ->
          length(rows)

        true ->
          with :ok <- upsert_rows(rows, actor),
               :ok <- prune_removed(group_id, rows, actor) do
            length(rows)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp lock_group(group_id) do
    %{rows: [[locked?]]} =
      Repo.query!(
        "SELECT pg_try_advisory_xact_lock(hashtext(CAST($1 AS text)), hashtext(CAST($2 AS text)))",
        [@lock_class, group_id]
      )

    locked?
  end

  defp stored_keys(group_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT target, device_uid, source
        FROM platform.sweep_group_declared_targets
        WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid)
        """,
        [group_id]
      )

    rows
    |> Enum.map(fn [target, device_uid, source] -> {target, device_uid, source} end)
    |> Enum.sort()
  end

  defp upsert_rows(rows, actor) do
    if rows == [] do
      :ok
    else
      case Ash.bulk_create(rows, SweepGroupDeclaredTarget, :upsert,
             actor: actor,
             domain: SweepJobs,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success} ->
          :ok

        %Ash.BulkResult{} = result ->
          Logger.warning(
            "DeclaredTargets: declared-target upsert failed " <>
              "count=#{result.error_count} errors=#{inspect(result.errors)}"
          )

          {:error, {:declared_targets_upsert_failed, result.error_count}}
      end
    end
  end

  defp prune_removed(group_id, rows, actor) do
    keep_targets = Enum.map(rows, & &1.target)

    query =
      SweepGroupDeclaredTarget
      |> Ash.Query.filter(sweep_group_id == ^group_id)
      |> Ash.Query.filter(target not in ^keep_targets)

    case Ash.bulk_destroy(query, :destroy, %{},
           actor: actor,
           domain: SweepJobs,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{} = result ->
        Logger.warning(
          "DeclaredTargets: declared-target prune failed for group #{inspect(group_id)} " <>
            "count=#{result.error_count} errors=#{inspect(result.errors)}"
        )

        {:error, {:declared_targets_prune_failed, result.error_count}}
    end
  end
end
