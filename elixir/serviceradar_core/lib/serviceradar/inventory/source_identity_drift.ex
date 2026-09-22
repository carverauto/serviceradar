defmodule ServiceRadar.Inventory.SourceIdentityDrift do
  @moduledoc """
  Audit, report, and repair helpers for source-authoritative identity drift.

  Armis is the first concrete source because its northbound workflow must not
  update the wrong external device. The data shape is intentionally generic so
  future typed integrations can use the same persisted diagnostics table.
  """

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Repo

  require Logger

  @open_conflict_target {:unsafe_fragment,
                         "(source_type, COALESCE(source_id, ''), conflict_category, " <>
                           "COALESCE(device_uid, ''), COALESCE(source_identifier_type, ''), " <>
                           "COALESCE(source_identifier_value, '')) WHERE status = 'open'"}
  @default_example_limit 10
  @default_repair_limit 5_000
  @postgres_bind_parameter_limit 65_535
  @insert_bind_parameter_headroom 1_024
  @max_insert_bind_parameters @postgres_bind_parameter_limit - @insert_bind_parameter_headroom

  # Categories produced by the periodic drift audit (audit_and_persist/1).
  # `active_ip_conflict` is intentionally excluded — those rows are written by
  # the sync ingestion path (record_active_ip_conflict/3), not the audit, so the
  # audit must never auto-clear them during reconciliation.
  @audit_conflict_categories [
    "multiple_typed_ids_per_device",
    "typed_id_on_multiple_devices",
    "metadata_identifier_disagreement",
    "split_typed_generic_identifier",
    "source_linkage_conflict"
  ]

  # Conflict categories that actually withhold a device from the northbound
  # outbound set — the armis_identity_consistent_predicate excludes exactly
  # these. Only these count toward a run's skipped_count so it stays disjoint
  # from the devices actually sent: a device sharing its typed id with another
  # device (typed_id_on_multiple_devices) or with mixed source linkage
  # (source_linkage_conflict) can still be sent, and active_ip_conflict is a
  # sync-side signal, so none of those should inflate the skip count.
  @withholding_conflict_categories [
    "metadata_identifier_disagreement",
    "multiple_typed_ids_per_device",
    "split_typed_generic_identifier"
  ]

  # Compile-time constant (no user input) scoping the cached open-conflict read
  # to this source's id ($1). Blank/unlinked-source conflicts are intentionally
  # NOT attributed to a specific source's run (that inflated every source).
  @source_conflict_scope "status = 'open' AND source_type = 'armis' AND source_id = $1"

  @doc """
  Run the repeatable Armis source-identity drift audit.
  """
  def audit_armis(opts \\ []) do
    source_id = normalize_string(Keyword.get(opts, :source_id))

    conflicts =
      []
      |> Kernel.++(multiple_typed_ids_per_device())
      |> Kernel.++(typed_id_on_multiple_devices())
      |> Kernel.++(metadata_identifier_disagreements())
      |> Kernel.++(split_typed_generic_identifiers())
      |> Kernel.++(source_linkage_conflicts())
      |> maybe_filter_source(source_id)
      |> Enum.uniq_by(&conflict_key/1)

    %{
      source_type: "armis",
      source_id: source_id,
      conflicts: conflicts,
      summary: summarize_conflicts(conflicts)
    }
  end

  @doc """
  Read the persisted open-conflict report for a source (northbound hot path).

  This does NOT recompute the drift audit; it reads counts and a bounded set of
  examples straight from `platform.source_identity_conflicts` using the
  status/source indexes. The audit itself runs on a lower cadence in
  `ArmisNorthboundConflictAuditWorker` via `audit_and_persist/1`, so the
  per-source northbound run no longer pays for five global aggregations plus a
  full conflict re-upsert on every push.
  """
  def source_conflict_report(source, opts \\ []) do
    source_id = source_id(source)
    limit = Keyword.get(opts, :identity_conflict_example_limit) || @default_example_limit
    categories = open_conflict_category_counts(source_id)

    %{
      "total_count" => categories |> Map.values() |> Enum.sum(),
      "skipped_count" => open_withheld_device_count(source_id),
      "categories" => categories,
      "examples" => open_conflict_examples(source_id, limit)
    }
  rescue
    e ->
      Logger.warning("SourceIdentityDrift: failed to read source conflict report: #{inspect(e)}")
      empty_conflict_report()
  end

  @doc """
  Recompute the global Armis drift audit, persist it, and reconcile.

  This is intentionally global (never source-scoped): reconciliation clears
  previously-open audit-category conflicts that the current pass no longer
  detects, which is only sound when the audit covered every source. A
  source-scoped audit would leave other sources' still-valid conflicts undetected
  and wrongly clear them. Detected conflicts are upserted (idempotent on the open
  partial index); stale ones are marked `cleared` so the cached counts read by
  the northbound runner self-correct. Sync-written `active_ip_conflict` rows are
  never touched. Runs on a lower cadence off the per-source run hot path.
  """
  def audit_and_persist(opts \\ []) do
    started_at = DateTime.utc_now()
    audit = Keyword.get(opts, :audit_fun, &audit_armis/0).()
    persist_fun = Keyword.get(opts, :persist_fun, &record_conflicts/1)

    case persist_fun.(audit.conflicts) do
      :ok ->
        %{
          audited_count: length(audit.conflicts),
          cleared_count: clear_stale_audit_conflicts(started_at),
          summary: audit.summary
        }

      {:error, reason} = error ->
        Logger.warning("SourceIdentityDrift: audit persistence failed: #{inspect(reason)}")
        error

      other ->
        error = {:unexpected_persist_result, other}
        Logger.warning("SourceIdentityDrift: audit persistence failed: #{inspect(error)}")
        {:error, error}
    end
  rescue
    e ->
      Logger.warning("SourceIdentityDrift: audit_and_persist failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Run the Armis dry-run/apply repair pass.

  Dry-run is the default. Apply mode only repairs high-confidence metadata drift
  where one active device has exactly one typed Armis identifier, that identifier
  is not shared with another active row, and no split generic Armis identifier
  exists for the same value.
  """
  def repair_armis(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    source_id = normalize_string(Keyword.get(opts, :source_id))
    limit = Keyword.get(opts, :limit, @default_repair_limit)

    audit = audit_armis(source_id: source_id)
    safe_repairs = safe_armis_metadata_repairs(source_id: source_id, limit: limit)

    if Keyword.get(opts, :record_conflicts, true) do
      _ = record_conflicts(audit.conflicts)
    end

    applied_repairs =
      if apply? do
        apply_armis_metadata_repairs(safe_repairs, Keyword.get(opts, :actor, "mix_task"))
      else
        []
      end

    %{
      mode: if(apply?, do: "apply", else: "dry_run"),
      source_type: "armis",
      source_id: source_id,
      conflicts: audit.conflicts,
      repairs: safe_repairs,
      applied_repairs: applied_repairs,
      summary:
        Map.merge(audit.summary, %{
          "safe_repair_count" => length(safe_repairs),
          "applied_repair_count" => length(applied_repairs)
        })
    }
  end

  @doc """
  Persist source identity conflicts idempotently.
  """
  def record_conflicts([]), do: :ok

  def record_conflicts(conflicts) when is_list(conflicts) do
    now = DateTime.utc_now()

    rows =
      conflicts
      |> Enum.map(&conflict_row(&1, now))
      |> Enum.reject(&is_nil/1)

    case rows do
      [] ->
        :ok

      rows ->
        case persist_conflict_rows(rows) do
          :ok -> :ok
          {:error, reason} -> persist_error(reason)
        end
    end
  rescue
    e -> persist_error(e)
  end

  @doc """
  Build the active-IP source-identity conflict for a record whose strong
  identity refused to rebind to an unrelated IP owner, and emit telemetry.

  Returns the conflict map (or `nil` for a non-map record). Callers persist it —
  collect many and pass them to `record_conflicts/1` in one write instead of
  issuing a separate insert per IP collision.
  """
  def build_active_ip_conflict(record, existing_device_uid, ip) when is_map(record) do
    metadata = Map.get(record, :metadata) || %{}

    ids =
      Ids.extract_strong_identifiers(%{
        device_id: Map.get(record, :device_id) || Map.get(record, :uid),
        ip: ip,
        mac: Map.get(record, :mac),
        metadata: metadata,
        partition: "default"
      })

    {identifier_type, identifier_value} = Ids.highest_priority_identifier(ids)

    conflict = %{
      source_type: source_type(metadata),
      source_id: normalize_string(metadata["sync_service_id"]),
      source_identifier_type: stringify(identifier_type),
      source_identifier_value: identifier_value,
      device_uid: Map.get(record, :uid),
      current_ip: ip,
      current_mac: Map.get(record, :mac),
      site: extract_site(metadata),
      conflict_category: "active_ip_conflict",
      conflicting_identifiers: %{
        "incoming_device_uid" => Map.get(record, :uid),
        "existing_device_uid" => existing_device_uid,
        "ip" => ip,
        "source_identifier_type" => stringify(identifier_type),
        "source_identifier_value" => identifier_value
      },
      proposed_action: "preserve_source_identity_drop_conflicting_ip",
      confidence: "high",
      metadata: %{
        "reason" => "active_ip_owner_did_not_match_source_authoritative_identifier"
      }
    }

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :source_identity, :active_ip_conflict],
      %{count: 1},
      %{
        source_type: conflict.source_type,
        source_id: conflict.source_id,
        source_identifier_type: identifier_type,
        source_identifier_value: identifier_value,
        incoming_device_uid: Map.get(record, :uid),
        existing_device_uid: existing_device_uid,
        ip: ip
      }
    )

    conflict
  end

  def build_active_ip_conflict(_record, _existing_device_uid, _ip), do: nil

  @doc """
  Persist and emit telemetry for a single active-IP recovery conflict.
  """
  def record_active_ip_conflict(record, existing_device_uid, ip) do
    case build_active_ip_conflict(record, existing_device_uid, ip) do
      nil -> :ok
      conflict -> record_conflicts([conflict])
    end
  end

  @doc """
  Summarize conflict maps for run metadata and reports.
  """
  def summarize_conflicts(conflicts) when is_list(conflicts) do
    category_counts =
      conflicts
      |> Enum.frequencies_by(&string_value(&1, :conflict_category))
      |> Enum.reject(fn {category, _count} -> category in [nil, ""] end)
      |> Map.new()

    %{
      "total_count" => length(conflicts),
      "categories" => category_counts
    }
  end

  def summarize_conflicts(_), do: %{"total_count" => 0, "categories" => %{}}

  def format_conflict_report(conflicts, limit \\ @default_example_limit)
      when is_list(conflicts) do
    limit = limit || @default_example_limit

    conflicts
    |> summarize_conflicts()
    |> Map.put("examples", Enum.take(Enum.map(conflicts, &conflict_example/1), limit))
  end

  def empty_conflict_report do
    %{"total_count" => 0, "skipped_count" => 0, "categories" => %{}, "examples" => []}
  end

  def conflict_count(%{"total_count" => count}) when is_integer(count), do: count
  def conflict_count(%{total_count: count}) when is_integer(count), do: count
  def conflict_count(_), do: 0

  @doc """
  Count of conflicts that withhold a device from the northbound outbound set.

  Used to keep a run's skipped_count/device_count disjoint from the devices
  actually sent. Falls back to the total conflict count for reports that do not
  carry a `skipped_count` (e.g. injected/legacy reports).
  """
  def withheld_conflict_count(%{"skipped_count" => count}) when is_integer(count), do: count
  def withheld_conflict_count(%{skipped_count: count}) when is_integer(count), do: count
  def withheld_conflict_count(report), do: conflict_count(report)

  defp multiple_typed_ids_per_device do
    """
    SELECT
      d.uid AS device_uid,
      d.ip AS current_ip,
      d.mac AS current_mac,
      d.hostname AS hostname,
      d.metadata AS metadata,
      NULLIF(d.metadata->>'sync_service_id', '') AS device_source_id,
      array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL) AS source_ids,
      array_agg(DISTINCT di.identifier_value ORDER BY di.identifier_value) AS typed_armis_ids
    FROM platform.ocsf_devices d
    JOIN platform.device_identifiers di
      ON di.device_id = d.uid
     AND di.identifier_type = 'armis_device_id'
     AND NULLIF(di.identifier_value, '') IS NOT NULL
    WHERE d.deleted_at IS NULL
    GROUP BY d.uid
    HAVING count(DISTINCT di.identifier_value) > 1
    """
    |> query_maps()
    |> Enum.map(fn row ->
      typed = list(row["typed_armis_ids"])

      build_conflict(row, %{
        conflict_category: "multiple_typed_ids_per_device",
        source_identifier_type: "armis_device_id",
        source_identifier_value: List.first(typed),
        conflicting_identifiers: %{
          "typed_armis_ids" => typed,
          "source_ids" => source_ids(row)
        },
        proposed_action: "manual_review_split_or_merge",
        confidence: "ambiguous",
        metadata: %{"hostname" => row["hostname"]}
      })
    end)
  end

  defp typed_id_on_multiple_devices do
    """
    WITH shared AS (
      SELECT
        di.identifier_value,
        di.partition,
        array_agg(DISTINCT di.device_id ORDER BY di.device_id) AS affected_device_uids
      FROM platform.device_identifiers di
      JOIN platform.ocsf_devices d
        ON d.uid = di.device_id
       AND d.deleted_at IS NULL
      WHERE di.identifier_type = 'armis_device_id'
        AND NULLIF(di.identifier_value, '') IS NOT NULL
      GROUP BY di.identifier_value, di.partition
      HAVING count(DISTINCT di.device_id) > 1
    )
    SELECT
      d.uid AS device_uid,
      d.ip AS current_ip,
      d.mac AS current_mac,
      d.hostname AS hostname,
      d.metadata AS metadata,
      COALESCE(NULLIF(di.metadata->>'sync_service_id', ''), NULLIF(d.metadata->>'sync_service_id', '')) AS source_id,
      di.identifier_value AS armis_device_id,
      shared.affected_device_uids AS affected_device_uids
    FROM shared
    JOIN platform.device_identifiers di
      ON di.identifier_type = 'armis_device_id'
     AND di.identifier_value = shared.identifier_value
     AND di.partition = shared.partition
    JOIN platform.ocsf_devices d
      ON d.uid = di.device_id
     AND d.deleted_at IS NULL
    """
    |> query_maps()
    |> Enum.map(fn row ->
      build_conflict(row, %{
        conflict_category: "typed_id_on_multiple_devices",
        source_identifier_type: "armis_device_id",
        source_identifier_value: row["armis_device_id"],
        source_id: row["source_id"],
        conflicting_identifiers: %{
          "armis_device_id" => row["armis_device_id"],
          "affected_device_uids" => list(row["affected_device_uids"])
        },
        proposed_action: "manual_review_merge_or_reassign_identifier",
        confidence: "ambiguous",
        metadata: %{"hostname" => row["hostname"]}
      })
    end)
  end

  defp metadata_identifier_disagreements do
    """
    WITH typed AS (
      SELECT
        di.device_id,
        array_agg(DISTINCT di.identifier_value ORDER BY di.identifier_value) AS typed_armis_ids,
        array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL) AS source_ids
      FROM platform.device_identifiers di
      WHERE di.identifier_type = 'armis_device_id'
        AND NULLIF(di.identifier_value, '') IS NOT NULL
      GROUP BY di.device_id
    )
    SELECT
      d.uid AS device_uid,
      d.ip AS current_ip,
      d.mac AS current_mac,
      d.hostname AS hostname,
      d.metadata AS metadata,
      COALESCE(NULLIF(d.metadata->>'sync_service_id', ''), typed.source_ids[1]) AS source_id,
      typed.typed_armis_ids AS typed_armis_ids,
      typed.typed_armis_ids[1] AS typed_armis_id,
      NULLIF(d.metadata->>'armis_device_id', '') AS metadata_armis_device_id,
      NULLIF(d.metadata->>'integration_id', '') AS metadata_integration_id,
      NULLIF(d.metadata->>'integration_type', '') AS metadata_integration_type
    FROM typed
    JOIN platform.ocsf_devices d
      ON d.uid = typed.device_id
     AND d.deleted_at IS NULL
    WHERE cardinality(typed.typed_armis_ids) = 1
      AND (
        (NULLIF(d.metadata->>'armis_device_id', '') IS NOT NULL
          AND d.metadata->>'armis_device_id' <> typed.typed_armis_ids[1])
        OR (
          COALESCE(d.metadata->>'integration_type', '') = 'armis'
          AND NULLIF(d.metadata->>'integration_id', '') IS NOT NULL
          AND d.metadata->>'integration_id' <> typed.typed_armis_ids[1]
          AND d.metadata->>'integration_id' IS DISTINCT FROM (
            'armis:' || NULLIF(
              array_to_string(
                array_remove(
                  regexp_split_to_array(lower(COALESCE(NULLIF(d.metadata->>'sync_service_id', ''), typed.source_ids[1])), '[[:space:]:]+'),
                  ''
                ),
                '-'
              ), ''
            ) || ':device:' || typed.typed_armis_ids[1]
          )
        )
      )
    """
    |> query_maps()
    |> Enum.map(fn row ->
      build_conflict(row, %{
        conflict_category: "metadata_identifier_disagreement",
        source_identifier_type: "armis_device_id",
        source_identifier_value: row["typed_armis_id"],
        source_id: row["source_id"],
        conflicting_identifiers: %{
          "typed_armis_id" => row["typed_armis_id"],
          "metadata_armis_device_id" => row["metadata_armis_device_id"],
          "metadata_integration_id" => row["metadata_integration_id"],
          "metadata_integration_type" => row["metadata_integration_type"]
        },
        proposed_action: "repair_metadata_to_typed_identifier",
        confidence: "high",
        metadata: %{"hostname" => row["hostname"]}
      })
    end)
  end

  defp split_typed_generic_identifiers do
    """
    SELECT
      d.uid AS device_uid,
      d.ip AS current_ip,
      d.mac AS current_mac,
      d.hostname AS hostname,
      d.metadata AS metadata,
      COALESCE(NULLIF(typed.metadata->>'sync_service_id', ''), NULLIF(d.metadata->>'sync_service_id', '')) AS source_id,
      typed.identifier_value AS armis_device_id,
      generic.device_id AS generic_device_uid,
      generic.metadata AS generic_identifier_metadata
    FROM platform.device_identifiers typed
    JOIN platform.ocsf_devices d
      ON d.uid = typed.device_id
     AND d.deleted_at IS NULL
    JOIN platform.device_identifiers generic
      ON generic.identifier_type = 'integration_id'
     AND generic.identifier_value = typed.identifier_value
     AND generic.device_id <> typed.device_id
     AND COALESCE(generic.metadata->>'integration_type', '') = 'armis'
     AND (
       generic.partition = typed.partition
       OR (
         generic.partition = 'default'
         AND COALESCE(generic.metadata->>'sync_service_id', '') =
             COALESCE(typed.metadata->>'sync_service_id', d.metadata->>'sync_service_id', '')
       )
     )
    JOIN platform.ocsf_devices generic_device
      ON generic_device.uid = generic.device_id
     AND generic_device.deleted_at IS NULL
    WHERE typed.identifier_type = 'armis_device_id'
      AND NULLIF(typed.identifier_value, '') IS NOT NULL
    """
    |> query_maps()
    |> Enum.map(fn row ->
      build_conflict(row, %{
        conflict_category: "split_typed_generic_identifier",
        source_identifier_type: "armis_device_id",
        source_identifier_value: row["armis_device_id"],
        source_id: row["source_id"],
        conflicting_identifiers: %{
          "armis_device_id" => row["armis_device_id"],
          "typed_device_uid" => row["device_uid"],
          "generic_device_uid" => row["generic_device_uid"],
          "generic_identifier_metadata" => row["generic_identifier_metadata"] || %{}
        },
        proposed_action: "manual_review_remove_or_reassign_generic_bridge",
        confidence: "ambiguous",
        metadata: %{"hostname" => row["hostname"]}
      })
    end)
  end

  defp source_linkage_conflicts do
    """
    SELECT
      d.uid AS device_uid,
      d.ip AS current_ip,
      d.mac AS current_mac,
      d.hostname AS hostname,
      d.metadata AS metadata,
      NULLIF(d.metadata->>'sync_service_id', '') AS device_source_id,
      array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL) AS identifier_source_ids,
      array_agg(DISTINCT di.identifier_value ORDER BY di.identifier_value) AS typed_armis_ids
    FROM platform.ocsf_devices d
    JOIN platform.device_identifiers di
      ON di.device_id = d.uid
     AND di.identifier_type = 'armis_device_id'
     AND NULLIF(di.identifier_value, '') IS NOT NULL
    WHERE d.deleted_at IS NULL
    GROUP BY d.uid
    HAVING cardinality(array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL)) > 1
       OR (
         NULLIF(d.metadata->>'sync_service_id', '') IS NOT NULL
         AND cardinality(array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL)) > 0
         AND NOT (NULLIF(d.metadata->>'sync_service_id', '') = ANY(array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL)))
       )
    """
    |> query_maps()
    |> Enum.map(fn row ->
      typed = list(row["typed_armis_ids"])

      build_conflict(row, %{
        conflict_category: "source_linkage_conflict",
        source_identifier_type: "armis_device_id",
        source_identifier_value: List.first(typed),
        source_id: row["device_source_id"] || List.first(list(row["identifier_source_ids"])),
        conflicting_identifiers: %{
          "typed_armis_ids" => typed,
          "device_source_id" => row["device_source_id"],
          "identifier_source_ids" => list(row["identifier_source_ids"])
        },
        proposed_action: "manual_review_source_linkage",
        confidence: "ambiguous",
        metadata: %{"hostname" => row["hostname"]}
      })
    end)
  end

  defp safe_armis_metadata_repairs(opts) do
    source_id = normalize_string(Keyword.get(opts, :source_id))
    limit = Keyword.get(opts, :limit, @default_repair_limit)

    rows =
      query_maps(
        """
        WITH typed AS (
          SELECT
            di.device_id,
            array_agg(DISTINCT di.identifier_value ORDER BY di.identifier_value) AS typed_armis_ids,
            array_remove(array_agg(DISTINCT NULLIF(di.metadata->>'sync_service_id', '')), NULL) AS source_ids
          FROM platform.device_identifiers di
          WHERE di.identifier_type = 'armis_device_id'
            AND NULLIF(di.identifier_value, '') IS NOT NULL
          GROUP BY di.device_id
        ),
        duplicate_ids AS (
          SELECT di.identifier_value
          FROM platform.device_identifiers di
          JOIN platform.ocsf_devices d ON d.uid = di.device_id AND d.deleted_at IS NULL
          WHERE di.identifier_type = 'armis_device_id'
          GROUP BY di.identifier_value
          HAVING count(DISTINCT di.device_id) > 1
        )
        SELECT
          d.uid AS device_uid,
          d.ip AS current_ip,
          d.mac AS current_mac,
          d.hostname AS hostname,
          d.metadata AS metadata,
          COALESCE(NULLIF(d.metadata->>'sync_service_id', ''), typed.source_ids[1]) AS source_id,
          typed.typed_armis_ids[1] AS typed_armis_id,
          NULLIF(d.metadata->>'armis_device_id', '') AS old_armis_device_id,
          NULLIF(d.metadata->>'integration_id', '') AS old_integration_id,
          NULLIF(d.metadata->>'integration_type', '') AS integration_type
        FROM typed
        JOIN platform.ocsf_devices d
          ON d.uid = typed.device_id
         AND d.deleted_at IS NULL
        WHERE cardinality(typed.typed_armis_ids) = 1
          AND (
            (NULLIF(d.metadata->>'armis_device_id', '') IS NOT NULL
              AND d.metadata->>'armis_device_id' <> typed.typed_armis_ids[1])
            OR (
              COALESCE(d.metadata->>'integration_type', '') = 'armis'
              AND NULLIF(d.metadata->>'integration_id', '') IS NOT NULL
              AND d.metadata->>'integration_id' <> typed.typed_armis_ids[1]
              AND d.metadata->>'integration_id' IS DISTINCT FROM (
                'armis:' || NULLIF(
                  array_to_string(
                    array_remove(
                      regexp_split_to_array(lower(COALESCE(NULLIF(d.metadata->>'sync_service_id', ''), typed.source_ids[1])), '[[:space:]:]+'),
                      ''
                    ),
                    '-'
                  ), ''
                ) || ':device:' || typed.typed_armis_ids[1]
              )
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM duplicate_ids dup WHERE dup.identifier_value = typed.typed_armis_ids[1]
          )
          AND NOT EXISTS (
            SELECT 1
            FROM platform.device_identifiers generic
            JOIN platform.ocsf_devices gd ON gd.uid = generic.device_id AND gd.deleted_at IS NULL
            WHERE generic.identifier_type = 'integration_id'
              AND generic.identifier_value = typed.typed_armis_ids[1]
              AND generic.device_id <> d.uid
              AND COALESCE(generic.metadata->>'integration_type', '') = 'armis'
          )
        ORDER BY d.uid
        LIMIT $1
        """,
        [limit]
      )

    rows
    |> Enum.map(&repair_row/1)
    |> maybe_filter_source(source_id)
  end

  defp apply_armis_metadata_repairs(repairs, actor) do
    Enum.flat_map(repairs, fn repair ->
      patch = metadata_repair_patch(repair, actor)

      case apply_and_verify_metadata_repair(repair, patch) do
        {:ok, applied} ->
          [applied]

        {:error, reason} ->
          Logger.warning(
            "SourceIdentityDrift: failed to repair Armis metadata for #{repair.device_uid}: #{inspect(reason)}"
          )

          []
      end
    end)
  end

  defp apply_and_verify_metadata_repair(repair, patch) do
    Repo.transaction(fn ->
      with {:ok, %{num_rows: 1}} <-
             Repo.query(
               """
               UPDATE platform.ocsf_devices
               SET metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb,
                   modified_time = timezone('utc', now())
               WHERE uid = $1
                 AND deleted_at IS NULL
               """,
               # Pass the map itself. The `$2::jsonb` placeholder makes Postgres
               # type the parameter as jsonb, so Postgrex runs it through its own
               # JSON encoder -- a pre-encoded binary here gets encoded AGAIN and
               # lands as a jsonb *string scalar*.
               [repair.device_uid, patch]
             ),
           :ok <- verify_metadata_repair(repair) do
        audit = Map.fetch!(patch, "source_identity_repair")
        _ = mark_metadata_repair_resolved(repair, audit)
        Map.put(repair, :repair_audit, audit)
      else
        {:ok, %{num_rows: count}} -> Repo.rollback({:repair_update_count_mismatch, count})
        {:error, reason} -> Repo.rollback(reason)
        other -> Repo.rollback({:unexpected_repair_result, other})
      end
    end)
  end

  defp verify_metadata_repair(repair) do
    case Repo.query(
           """
           SELECT metadata
           FROM platform.ocsf_devices
           WHERE uid = $1
             AND deleted_at IS NULL
           """,
           [repair.device_uid]
         ) do
      {:ok, %{rows: [[metadata]]}} when is_map(metadata) ->
        armis_matches? = metadata["armis_device_id"] == repair.typed_armis_id

        integration_matches? =
          repair.integration_type != "armis" or
            metadata["integration_id"] == repair.integration_id

        if armis_matches? and integration_matches?,
          do: :ok,
          else: {:error, :metadata_repair_reread_mismatch}

      {:ok, %{rows: rows}} ->
        {:error, {:metadata_repair_reread_count_mismatch, length(rows)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_metadata_repair_resolved(repair, audit) do
    Repo.query(
      """
      UPDATE platform.source_identity_conflicts
      SET status = 'resolved',
          resolved_at = timezone('utc', now()),
          repair_audit = $4::jsonb,
          updated_at = timezone('utc', now())
      WHERE status = 'open'
        AND source_type = 'armis'
        AND conflict_category = 'metadata_identifier_disagreement'
        AND COALESCE(device_uid, '') = $1
        AND COALESCE(source_identifier_type, '') = 'armis_device_id'
        AND COALESCE(source_identifier_value, '') = $2
        AND COALESCE(source_id, '') = COALESCE($3, '')
      """,
      # `audit` goes in as a map for the same reason as the metadata patch
      # above: `$4::jsonb` means Postgrex encodes it, so pre-encoding here
      # would store a jsonb string scalar instead of an object.
      [repair.device_uid, repair.typed_armis_id, repair.source_id, audit]
    )
  rescue
    e ->
      Logger.warning("SourceIdentityDrift: failed to mark repair resolved: #{inspect(e)}")
      {:error, e}
  end

  defp metadata_repair_patch(repair, actor) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    audit = %{
      "actor" => to_string(actor || "unknown"),
      "reason" => "metadata_identifier_disagreement",
      "repaired_at" => now,
      "prior" => %{
        "armis_device_id" => repair.old_armis_device_id,
        "integration_id" => repair.old_integration_id
      },
      "repaired" => %{
        "armis_device_id" => repair.typed_armis_id,
        "integration_id" => if(repair.integration_type == "armis", do: repair.integration_id)
      }
    }

    maybe_put(
      %{"armis_device_id" => repair.typed_armis_id, "source_identity_repair" => audit},
      "integration_id",
      if(repair.integration_type == "armis", do: repair.integration_id)
    )
  end

  defp repair_row(row) do
    metadata = row["metadata"] || %{}

    integration_id =
      if String.contains?(row["old_integration_id"] || "", ":") do
        IntegrationIdentity.scoped_device_id("armis", row["source_id"], row["typed_armis_id"])
      end

    %{
      integration_id: integration_id || row["typed_armis_id"],
      source_type: "armis",
      source_id: normalize_string(row["source_id"]),
      source_identifier_type: "armis_device_id",
      source_identifier_value: row["typed_armis_id"],
      device_uid: row["device_uid"],
      current_ip: row["current_ip"],
      current_mac: row["current_mac"],
      site: extract_site(metadata),
      typed_armis_id: row["typed_armis_id"],
      old_armis_device_id: row["old_armis_device_id"],
      old_integration_id: row["old_integration_id"],
      integration_type: row["integration_type"],
      conflict_category: "metadata_identifier_disagreement",
      conflicting_identifiers: %{
        "typed_armis_id" => row["typed_armis_id"],
        "metadata_armis_device_id" => row["old_armis_device_id"],
        "metadata_integration_id" => row["old_integration_id"]
      },
      proposed_action: "repair_metadata_to_typed_identifier",
      confidence: "high",
      metadata: %{"hostname" => row["hostname"]}
    }
  end

  defp build_conflict(row, attrs) do
    metadata = row["metadata"] || %{}

    %{
      source_type: Map.get(attrs, :source_type, "armis"),
      source_id:
        normalize_string(
          Map.get(attrs, :source_id) || row["source_id"] || row["device_source_id"] ||
            List.first(source_ids(row))
        ),
      source_identifier_type: Map.get(attrs, :source_identifier_type),
      source_identifier_value: normalize_string(Map.get(attrs, :source_identifier_value)),
      device_uid: row["device_uid"],
      current_ip: row["current_ip"],
      current_mac: row["current_mac"],
      site: extract_site(metadata),
      conflict_category: Map.fetch!(attrs, :conflict_category),
      conflicting_identifiers: Map.get(attrs, :conflicting_identifiers, %{}),
      proposed_action: Map.get(attrs, :proposed_action),
      confidence: Map.get(attrs, :confidence),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp conflict_row(conflict, now) do
    category = string_value(conflict, :conflict_category)
    source_type = string_value(conflict, :source_type) || "unknown"

    if category in [nil, ""] do
      nil
    else
      %{
        source_type: source_type,
        source_id: string_value(conflict, :source_id),
        source_identifier_type: string_value(conflict, :source_identifier_type),
        source_identifier_value: string_value(conflict, :source_identifier_value),
        device_uid: string_value(conflict, :device_uid),
        current_ip: string_value(conflict, :current_ip),
        current_mac: string_value(conflict, :current_mac),
        site: map_value(conflict, :site),
        conflict_category: category,
        conflicting_identifiers: map_value(conflict, :conflicting_identifiers),
        proposed_action: string_value(conflict, :proposed_action),
        confidence: string_value(conflict, :confidence),
        status: "open",
        first_detected_at: now,
        last_detected_at: now,
        repair_audit: %{},
        metadata: map_value(conflict, :metadata),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp persist_conflict_rows(rows) do
    chunk_size = max_rows_per_insert(rows)

    case Repo.transaction(
           fn ->
             rows
             |> Enum.chunk_every(chunk_size)
             |> Enum.each(&insert_conflict_chunk/1)
           end,
           timeout: :infinity
         ) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_conflict_chunk(rows) do
    Repo.insert_all(
      "source_identity_conflicts",
      rows,
      prefix: "platform",
      on_conflict:
        {:replace,
         [
           :last_detected_at,
           :current_ip,
           :current_mac,
           :site,
           :conflicting_identifiers,
           :proposed_action,
           :confidence,
           :metadata,
           :updated_at
         ]},
      conflict_target: @open_conflict_target
    )

    :ok
  end

  defp max_rows_per_insert(rows) do
    bound_column_count =
      rows
      |> Enum.reduce(MapSet.new(), fn row, columns ->
        Enum.reduce(Map.keys(row), columns, &MapSet.put(&2, &1))
      end)
      |> MapSet.size()
      |> max(1)

    max(1, div(@max_insert_bind_parameters, bound_column_count))
  end

  defp persist_error(reason) do
    Logger.warning("SourceIdentityDrift: failed to persist conflicts: #{inspect(reason)}")
    {:error, reason}
  end

  defp open_conflict_category_counts(source_id) do
    ("SELECT conflict_category, count(*)::bigint AS count " <>
       "FROM platform.source_identity_conflicts " <>
       "WHERE #{@source_conflict_scope} GROUP BY conflict_category")
    |> query_maps([source_id])
    |> Enum.reduce(%{}, fn row, acc ->
      case normalize_string(row["conflict_category"]) do
        nil -> acc
        category -> Map.put(acc, category, to_integer(row["count"]))
      end
    end)
  end

  defp open_withheld_device_count(source_id) do
    ("SELECT count(DISTINCT device_uid)::bigint AS count " <>
       "FROM platform.source_identity_conflicts " <>
       "WHERE #{@source_conflict_scope} " <>
       "AND conflict_category = ANY($2)")
    |> query_maps([source_id, @withholding_conflict_categories])
    |> case do
      [%{"count" => count}] -> to_integer(count)
      _ -> 0
    end
  end

  defp open_conflict_examples(source_id, limit) do
    ("SELECT conflict_category, device_uid, source_id, source_identifier_type, " <>
       "source_identifier_value, current_ip, current_mac, proposed_action, confidence " <>
       "FROM platform.source_identity_conflicts " <>
       "WHERE #{@source_conflict_scope} ORDER BY last_detected_at DESC LIMIT $2")
    |> query_maps([source_id, limit])
    |> Enum.map(&conflict_example/1)
  end

  defp clear_stale_audit_conflicts(started_at) do
    %{num_rows: cleared} =
      Repo.query!(
        "UPDATE platform.source_identity_conflicts " <>
          "SET status = 'cleared', updated_at = timezone('utc', now()) " <>
          "WHERE status = 'open' AND source_type = 'armis' " <>
          "AND conflict_category = ANY($1) AND last_detected_at < $2",
        [@audit_conflict_categories, started_at]
      )

    cleared
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_integer(_), do: 0

  defp query_maps(sql, params \\ []) do
    %{columns: columns, rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  defp maybe_filter_source(conflicts, nil), do: conflicts

  defp maybe_filter_source(conflicts, source_id) do
    Enum.filter(conflicts, fn conflict ->
      conflict_source_id = string_value(conflict, :source_id)

      conflict_source_id in [nil, "", source_id] or
        source_id in source_ids(%{
          "source_ids" => get_in(conflict, [:conflicting_identifiers, "source_ids"])
        }) or
        source_id in source_ids(%{
          "identifier_source_ids" =>
            get_in(conflict, [:conflicting_identifiers, "identifier_source_ids"])
        })
    end)
  end

  defp conflict_example(conflict) do
    %{
      "category" => string_value(conflict, :conflict_category),
      "device_uid" => string_value(conflict, :device_uid),
      "source_id" => string_value(conflict, :source_id),
      "source_identifier_type" => string_value(conflict, :source_identifier_type),
      "source_identifier_value" => string_value(conflict, :source_identifier_value),
      "current_ip" => string_value(conflict, :current_ip),
      "current_mac" => string_value(conflict, :current_mac),
      "proposed_action" => string_value(conflict, :proposed_action),
      "confidence" => string_value(conflict, :confidence)
    }
  end

  defp conflict_key(conflict) do
    {
      string_value(conflict, :source_type),
      string_value(conflict, :source_id),
      string_value(conflict, :conflict_category),
      string_value(conflict, :device_uid),
      string_value(conflict, :source_identifier_type),
      string_value(conflict, :source_identifier_value)
    }
  end

  defp source_id(source) when is_map(source) do
    source
    |> Map.get(:id, Map.get(source, "id"))
    |> normalize_string()
  end

  defp source_id(_source), do: nil

  defp source_type(metadata) when is_map(metadata) do
    metadata
    |> Map.get("integration_type", "unknown")
    |> normalize_string()
    |> case do
      nil -> "unknown"
      value -> value
    end
  end

  defp source_type(_metadata), do: "unknown"

  defp source_ids(row) do
    []
    |> Kernel.++(list(row["source_ids"]))
    |> Kernel.++(list(row["identifier_source_ids"]))
    |> maybe_append(row["device_source_id"])
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_site(%{"site" => site}) when is_map(site), do: site
  defp extract_site(%{"site" => site}) when is_binary(site), do: %{"name" => site}
  defp extract_site(%{"Site" => site}) when is_binary(site), do: %{"name" => site}
  defp extract_site(%{"location" => site}) when is_binary(site), do: %{"name" => site}
  defp extract_site(_metadata), do: %{}

  defp list(nil), do: []
  defp list(values) when is_list(values), do: values
  defp list(value), do: [value]

  defp maybe_append(values, nil), do: values
  defp maybe_append(values, ""), do: values
  defp maybe_append(values, value), do: values ++ [value]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(value), do: value |> to_string() |> normalize_string()

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)

  defp string_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp string_value(_map, _key), do: nil

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_value(_map, _key), do: %{}
end
