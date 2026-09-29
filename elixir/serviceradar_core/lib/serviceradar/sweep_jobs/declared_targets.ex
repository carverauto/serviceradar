defmodule ServiceRadar.SweepJobs.DeclaredTargets do
  @moduledoc """
  Persists the declared target relation for one sweep group.

  `platform.sweep_group_declared_targets` is the declared side of the
  `device_sweep_overlap` view (issue #4963): one row per (sweep group,
  target), refreshed when the group's targeting changes. See
  `SweepGroupDeclaredTarget` for the row semantics and
  `ServiceRadar.SweepJobs.DeclaredTargetsNotifier` for the trigger.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.SweepJobs
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupDeclaredTarget

  require Ash.Query
  require Logger

  @doc """
  Replaces the persisted declared-target rows for `group`.

  Upsert first, then prune rows the group no longer declares: a failure
  between the two leaves the previous snapshot visible rather than an empty
  declared side. Returns `{:ok, row_count}` or `{:error, reason}`.
  """
  @spec refresh(SweepGroup.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def refresh(%SweepGroup{} = group) do
    actor = SystemActor.system(:sweep_compiler)
    rows = build_rows(group)

    with :ok <- upsert_rows(rows, actor),
         :ok <- prune_removed(group.id, rows, actor) do
      {:ok, length(rows)}
    end
  end

  defp build_rows(group) do
    %{static: static, device: device} = SweepCompiler.declared_targets(group)
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
        sweep_group_id: group.id,
        target: target,
        device_uid: device_uid,
        source: source,
        declared_at: now
      }
    end
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
