defmodule ServiceRadar.Inventory.Remediation.SourceIdentityRepair do
  @moduledoc """
  Collection-bound dry-run classification of the records holding one source instance's
  source-authoritative identifiers (change `add-source-id-succession`, design D1).

  The identifier type and scope come from `SourceAuthorityGuard.collection_scope/2`: a source
  with no exact collections, or a scope that does not map to exactly one source instance, is
  not classified. Presence in the instance's latest exact, activated collection decides whether
  an identifier is current. A stale identifier is retirable when the retirement rule admits it
  (`ServiceRadar.Inventory.Identity.SourceRetirement.retirable/2`): absent from N consecutive
  exact collections under the current collection query, and last reported at least T ago, on a
  live record.

  The records classified are those holding more than one identifier of the type, or one the
  latest collection did not report. Shared canonical ownership is reported as evidence, never
  treated as proof that distinct identifiers are duplicate assets. Nothing is written: the
  retirement pass (`ServiceRadar.Inventory.Identity.SourceRetirementWorker`) retires what the
  rule admits.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Repo

  @default_limit 5_000
  @maximum_limit 10_000

  # The scope's identifiers and the ids the collection reported are read once each and meet in
  # one window over the id, which marks an identifier current when the collection reported it.
  # Only the device row is looked up per record, by uid through a subquery fenced with OFFSET 0,
  # and the merge audit is counted for the rows returned (the query shape note in
  # `ServiceRadar.Inventory.Identity.SourceRetirement`).
  @scoped_rows_sql """
  WITH tagged AS (
    SELECT di.device_id, di.identifier_value AS value, false AS reported
    FROM platform.device_identifiers di
    WHERE di.identifier_type = CAST($1 AS text)
      AND NULLIF(di.identifier_value, '') IS NOT NULL
      AND right(di.partition, char_length(CAST($2 AS text))) = CAST($2 AS text)
    UNION ALL
    SELECT NULL, o.source_object_id, true
    FROM platform.device_source_observations o
    WHERE o.partition = CAST($3 AS text)
      AND o.source = CAST($4 AS text)
      AND o.source_instance = CAST($5 AS text)
      AND o.collection_id = CAST($6 AS text)
      AND o.present = true
  ),
  marked AS (
    SELECT device_id, value, bool_or(reported) OVER (PARTITION BY value) AS current
    FROM tagged
  ),
  typed AS (
    SELECT device_id,
           array_agg(DISTINCT value ORDER BY value) AS typed_ids,
           COALESCE(
             array_agg(DISTINCT value ORDER BY value) FILTER (WHERE current),
             ARRAY[]::text[]
           ) AS current_ids
    FROM marked
    WHERE device_id IS NOT NULL
    GROUP BY device_id
  ),
  classified AS (
    SELECT typed.device_id,
           typed.typed_ids,
           typed.current_ids,
           d.deleted,
           count(*) OVER () AS total_count
    FROM typed
    CROSS JOIN LATERAL (
      SELECT d.deleted_at IS NOT NULL AS deleted
      FROM platform.ocsf_devices d
      WHERE d.uid = typed.device_id
      OFFSET 0
    ) AS d
    WHERE cardinality(typed.typed_ids) > 1
       OR cardinality(typed.current_ids) < cardinality(typed.typed_ids)
    ORDER BY typed.device_id
    LIMIT CAST($7 AS integer)
  )
  SELECT device_id,
         typed_ids,
         current_ids,
         deleted,
         (
           SELECT count(*)
           FROM platform.merge_audit audit
           WHERE audit.from_device_id = classified.device_id
              OR audit.to_device_id = classified.device_id
         ) AS merge_audit_count,
         total_count
  FROM classified
  ORDER BY device_id
  """

  @doc """
  Classifies the records of one source instance: `source` as in `device_source_snapshots`
  (`"armis"`), and `source_instance` the integration source id.

  `opts`: `:limit` (default 5,000, at most 10,000), `:partition` (default: the partition of the
  instance's latest activated collection), `:settings` (default: the stored
  `DeviceCleanupSettings`, read for N and T) and `:now`.
  """
  @spec dry_run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run(source, source_instance, opts \\ [])

  def dry_run(source, source_instance, opts)
      when is_binary(source) and is_binary(source_instance) do
    limit = bounded_limit(Keyword.get(opts, :limit, @default_limit))

    with {:ok, settings} <- settings(opts),
         {:ok, instance} <- instance(source, source_instance, opts),
         {:ok, ctx} <- retirement_context(instance, settings, opts),
         {:ok, rows, total_count} <- scoped_rows(ctx, limit) do
      retirable = retirable_ids(ctx, rows)

      classifications =
        Enum.map(rows, fn row ->
          row
          |> Map.put(:retirable_ids, Map.get(retirable, row.device_uid, []))
          |> classify_row()
        end)

      {:ok,
       %{
         mode: "dry_run",
         source: source,
         source_id: source_instance,
         identifier_type: Atom.to_string(ctx.scope.identifier_type),
         collection_id: ctx.collection.collection_id,
         collection_content_hash: ctx.collection.content_hash,
         collection_query_hash: ctx.collection.query_hash,
         collection_observed_at: ctx.collection.observed_at,
         retirement_enabled: settings.source_retirement_enabled,
         min_absent_collections: ctx.min_collections,
         min_absence_hours: ctx.min_absence_hours,
         total_count: total_count,
         returned_count: length(classifications),
         truncated: total_count > length(classifications),
         summary: Enum.frequencies_by(classifications, & &1.classification),
         retirable_count: classifications |> Enum.map(&length(&1.retirable_ids)) |> Enum.sum(),
         classifications: classifications
       }}
    end
  end

  def dry_run(_source, _source_instance, _opts), do: {:error, :invalid_source_instance}

  @doc false
  def classify_row(row) do
    typed_ids = normalize_ids(Map.get(row, :typed_ids))
    current_ids = normalize_ids(Map.get(row, :current_ids))
    stale_ids = typed_ids -- current_ids
    retirable_ids = Enum.filter(normalize_ids(Map.get(row, :retirable_ids)), &(&1 in stale_ids))

    {classification, proposed_action} =
      case {length(current_ids), retirable_ids} do
        {count, _retirable} when count > 1 ->
          {"multiple_current_ids", "manual_source_alias_or_overmerge_review"}

        {0, []} ->
          {"no_current_ids", "review_historical_identity"}

        {0, _retirable} ->
          {"no_current_ids", "retire_stale_ids"}

        {1, []} ->
          {"one_current_id", "review_stale_ids_after_absence_grace"}

        {1, _retirable} ->
          {"one_current_id", "retire_stale_ids"}
      end

    %{
      device_uid: Map.get(row, :device_uid),
      classification: classification,
      typed_ids: typed_ids,
      current_ids: current_ids,
      stale_ids: stale_ids,
      retirable_ids: retirable_ids,
      deleted: Map.get(row, :deleted, false),
      merge_audit_count: Map.get(row, :merge_audit_count, 0),
      proposed_action: proposed_action,
      apply_eligible: retirable_ids != []
    }
  end

  defp settings(opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, %{} = settings} ->
        {:ok, settings}

      :error ->
        case DeviceCleanupSettings.get_settings(
               actor: SystemActor.system(:source_identity_repair)
             ) do
          {:ok, %DeviceCleanupSettings{} = settings} -> {:ok, settings}
          _other -> {:error, :settings_unavailable}
        end
    end
  end

  defp instance(source, source_instance, opts) do
    case Keyword.get(opts, :partition) || latest_partition(source, source_instance) do
      partition when is_binary(partition) ->
        {:ok, %{partition: partition, source: source, source_instance: source_instance}}

      nil ->
        {:error, :exact_source_snapshot_not_found}
    end
  end

  defp latest_partition(source, source_instance) do
    Repo.one(
      from(snapshot in "device_source_snapshots",
        where: snapshot.source == ^source and snapshot.source_instance == ^source_instance,
        order_by: [desc: snapshot.activated_at, desc: snapshot.id],
        limit: 1,
        select: snapshot.partition
      ),
      prefix: "platform"
    )
  end

  defp retirement_context(instance, settings, opts) do
    case SourceRetirement.context(instance,
           settings: settings,
           now: Keyword.get(opts, :now, DateTime.utc_now())
         ) do
      {:ok, ctx} -> {:ok, ctx}
      {:skip, :unscoped} -> {:error, :unscoped_source}
      {:skip, :no_exact_collection} -> {:error, :exact_source_snapshot_not_found}
    end
  end

  defp scoped_rows(ctx, limit) do
    instance = ctx.instance

    params = [
      Atom.to_string(ctx.scope.identifier_type),
      ctx.scope.partition_suffix,
      instance.partition,
      instance.source,
      instance.source_instance,
      ctx.collection.collection_id,
      limit
    ]

    case Repo.query(@scoped_rows_sql, params) do
      {:ok, %{rows: rows}} ->
        mapped =
          Enum.map(rows, fn [device_uid, typed_ids, current_ids, deleted, audit_count, _total] ->
            %{
              device_uid: device_uid,
              typed_ids: typed_ids,
              current_ids: current_ids,
              deleted: deleted,
              merge_audit_count: audit_count
            }
          end)

        total_count =
          case rows do
            [[_, _, _, _, _, total] | _] -> total
            [] -> 0
          end

        {:ok, mapped, total_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retirable_ids(_ctx, []), do: %{}

  defp retirable_ids(ctx, rows) do
    ctx
    |> SourceRetirement.retirable(Enum.map(rows, & &1.device_uid))
    |> Enum.group_by(& &1.device_id, & &1.identifier_value)
  end

  defp bounded_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @maximum_limit)

  defp bounded_limit(_limit), do: @default_limit

  defp normalize_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_ids(_ids), do: []
end
