defmodule ServiceRadar.Inventory.Identity.DuplicateSweep do
  @moduledoc """
  Scheduled duplicate reconciliation: builds identifier/IP indexes,
  union-finds transitive duplicate components, and merges each
  component into a canonical device (policy-gated via MergeEngine).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Query
  require Logger

  @doc """
  Reconcile duplicate devices by shared strong identifiers.

  Returns stats for observability and logging.
  """
  @spec reconcile_duplicates(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_duplicates(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:identity_reconciliation))
    max_merges = Keyword.get(opts, :max_merges, default_max_merges())
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Device identity reconciliation started")

    # Bounded: the database aggregates duplicate identifier groups (values
    # mapped to more than one device); the full identifier table is never
    # loaded into memory. Bare-IP overlap is NOT merge evidence (policy:
    # weak/medium evidence never merges devices), and neither are
    # locally-administered MACs or serial-only matches. Hardware serials are
    # useful during source-aware ingestion, where conflicting universal MACs
    # can veto convergence, but ambiguous legacy serial rows must not drive an
    # unattended scheduled merge.
    identifier_duplicates = duplicate_identifier_groups()

    components =
      identifier_duplicates
      |> build_duplicate_components()
      |> Enum.filter(&(length(&1) > 1))

    {merge_count, error_count} = merge_components(components, actor, max_merges)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    stats = %{
      duplicate_identifier_count: length(identifier_duplicates),
      duplicate_components: length(components),
      merges: merge_count,
      errors: error_count,
      duration_ms: duration_ms
    }

    Logger.info("Device identity reconciliation completed: #{inspect(stats)}")

    {:ok, stats}
  rescue
    error ->
      Logger.warning("Device identity reconciliation failed: #{inspect(error)}")
      {:error, error}
  end

  # The scheduled job runs every few minutes; cap merges per run so a bad
  # state converges gradually under the merge guards instead of mass-merging.
  defp default_max_merges do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_merges_per_run, 200)
  end

  # Duplicate identifier groups straight from the database: one row per
  # (type, value, partition) mapped to more than one device. Excludes
  # service-component devices, malformed MAC values, and locally-administered
  # MACs (medium confidence must never merge devices on its own).
  defp duplicate_identifier_groups do
    import Ecto.Query

    # identifier_type is an Ash.Type.Atom enum column, so the query must use
    # atoms — passing strings makes Ecto fail to dump them to the EctoType.
    types = automatic_merge_identifier_types()

    query =
      from(di in DeviceIdentifier,
        where: di.identifier_type in ^types,
        where: not like(di.device_id, "serviceradar:%"),
        where:
          di.identifier_type != :mac or
            fragment("? ~ '^[0-9A-F]{12}$'", di.identifier_value),
        group_by: [di.identifier_type, di.identifier_value, di.partition],
        having: count(fragment("DISTINCT ?", di.device_id)) > 1,
        select:
          {di.identifier_type, di.identifier_value, di.partition,
           fragment("array_agg(DISTINCT ?)", di.device_id)}
      )

    query
    |> ServiceRadar.Repo.all()
    |> Enum.reject(fn {type, value, _partition, _ids} ->
      to_string(type) == "mac" and Mac.locally_administered_mac?(value)
    end)
    |> Enum.map(fn {type, value, partition, device_ids} ->
      {{partition, type, value}, MapSet.new(device_ids)}
    end)
  end

  @doc false
  def automatic_merge_identifier_types do
    Ids.identifier_priority() -- [:hardware_serial]
  end

  defp build_duplicate_components(duplicate_entries) do
    duplicate_entries
    |> build_duplicate_parents()
    |> build_duplicate_groups()
  end

  defp build_duplicate_parents(duplicate_entries) do
    Enum.reduce(duplicate_entries, %{}, fn {_key, device_ids}, acc ->
      ids = device_ids |> MapSet.to_list() |> Enum.uniq()
      acc = Enum.reduce(ids, acc, &Map.put_new(&2, &1, &1))
      union_device_group(ids, acc)
    end)
  end

  defp union_device_group([first | rest], acc) do
    Enum.reduce(rest, acc, fn id, parents -> union_devices(parents, first, id) end)
  end

  defp union_device_group(_ids, acc), do: acc

  defp build_duplicate_groups(parents) do
    parents
    |> Map.keys()
    |> Enum.reduce(%{}, fn device_id, acc ->
      root = find_device_root(parents, device_id)
      Map.update(acc, root, [device_id], &[device_id | &1])
    end)
    |> Map.values()
  end

  defp find_device_root(parents, device_id) do
    parent = Map.get(parents, device_id, device_id)

    if parent == device_id do
      device_id
    else
      find_device_root(parents, parent)
    end
  end

  defp union_devices(parents, device_a, device_b) do
    root_a = find_device_root(parents, device_a)
    root_b = find_device_root(parents, device_b)

    if root_a == root_b do
      parents
    else
      Map.put(parents, root_b, root_a)
    end
  end

  defp merge_components(components, actor, max_merges) do
    Enum.reduce_while(components, {0, 0}, fn device_ids, {merged, errors} ->
      {merged_count, error_count, halted?} =
        merge_component_devices(device_ids, actor, max_merges, merged)

      total_merged = merged + merged_count
      total_errors = errors + error_count

      if halted? or (max_merges && total_merged >= max_merges) do
        {:halt, {total_merged, total_errors}}
      else
        {:cont, {total_merged, total_errors}}
      end
    end)
  end

  defp merge_component_devices(device_ids, actor, max_merges, merged_so_far) do
    canonical_id = choose_canonical_device_id(device_ids, actor)

    {local_merged, local_errors} =
      device_ids
      |> Enum.reject(&(&1 == canonical_id))
      |> Enum.reduce_while({0, 0}, fn from_id, acc ->
        merge_component_step(from_id, canonical_id, actor, max_merges, merged_so_far, acc)
      end)

    halted? = max_merges && merged_so_far + local_merged >= max_merges
    {local_merged, local_errors, halted?}
  end

  defp merge_component_step(from_id, canonical_id, actor, max_merges, merged_so_far, acc) do
    {local_merged, local_errors} = acc

    if max_merges && merged_so_far + local_merged >= max_merges do
      {:halt, {local_merged, local_errors}}
    else
      case merge_component_device(from_id, canonical_id, actor) do
        :ok -> {:cont, {local_merged + 1, local_errors}}
        {:error, _reason} -> {:cont, {local_merged, local_errors + 1}}
      end
    end
  end

  defp merge_component_device(from_id, canonical_id, actor) do
    case MergeEngine.merge_devices(from_id, canonical_id,
           actor: actor,
           reason: "identifier_backfill",
           details: %{source: "scheduled_reconciliation"}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to merge device #{from_id} into #{canonical_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp choose_canonical_device_id(device_ids, actor) do
    candidates = Enum.filter(device_ids, &Ids.serviceradar_uuid?/1)
    candidates = if candidates == [], do: device_ids, else: candidates

    Resolver.most_recent_device_id(candidates, actor) || List.first(candidates)
  end
end
