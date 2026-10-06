defmodule ServiceRadar.Inventory.Remediation.SourceIdVerification do
  @moduledoc """
  Step `source-id-verify`: the read-only checks V1-V8 of the source id remediation (change
  `add-source-id-succession`, design D11). The step never writes, and `DireRemediation` refuses
  it under `--execute`.

  Each check reports `:pass`, `:fail`, `:pending`, when it cannot be judged yet, or `:not_run`,
  when it has nothing to judge or needs a manifest it was not given. The source instances
  judged are those of `device_source_snapshots` that `SourceAuthorityGuard.collection_scope/2`
  scopes. An instance whose latest activated collection is not exact cannot be judged, so its
  part of a check is pending.

    * V1: per instance, the live records holding an id of the scope (its population gauge,
      `SourceRetirement.population/1`) and the retired-only records left unmarked (class 5),
      against the ids the latest exact collection reported: at most 1.02 per id, and none when
      it reported none.
    * V2: the retirement rule admits no id of a live record (`SourceRetirement.retirable/2`).
    * V3: no Armis id, the one source id with exact collections, appears in the `metadata` of
      more than one live, unmarked record of one integration source, apart from the values
      `:reviewed_source_ids` names (class 8, which is reviewed, never merged). A marked record
      leaves with the grace delete.
    * V4: no released-seed shell is live (`PopulationGauges.released_seed_shell/0`).
    * V5: V1-V4 pass after two complete collections of each instance, its latest activated
      collection among them, and one completed cycle of each sweep group, per agent, that ran
      in the day before the last batch, all started after the last batch finished.
    * V6: `device_revival_audit` has no row since the run started for a record the manifests
      name, apart from the rollback's own.
    * V7: the reconciliation runs since the run started report no failed run and no errors, and
      one started after the last batch. A blocked merge is not an error.
    * V8: no `source_succession` merge still in place joined a retired id and a current id that
      the latest exact collection of their instance both reports.

  `:verify_manifests` names the manifests of the runs to judge: the run started at the earliest
  header's `started_at`, and its last batch finished at the latest entry. Without them, V5 and
  V6 are not run and V7 judges the latest reconciliation run.

  The retire, succession and shell steps run V6, V7 and V8 after every batch
  (`finish_batch/4`) and stop at the first that fails.
  """

  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.Identity.PopulationGauges
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  @max_live_to_current 1.02
  @sample 20
  # The application name the rollback's transactions carry, which the revival trigger records.
  @rollback_application "dire_remediation_rollback"
  @collections_after 2
  # The manifest fields that name a device, besides the ids of an `ocsf_devices` entry.
  @uid_keys ["device_id", "merged", "survivor", "predecessor", "successor"]

  @type result :: :pass | :fail | :pending | :not_run
  @type check :: %{check: String.t(), result: result(), details: map()}

  @instances_sql """
  SELECT s.partition, s.source, s.source_instance
  FROM platform.device_source_snapshots AS s
  ORDER BY s.partition, s.source, s.source_instance
  """

  # V3: per integration source, the Armis ids in the metadata of more than one live, unmarked
  # record, apart from the values $1. $2 limits the groups returned, not the counts.
  @metadata_duplicates_sql """
  SELECT count(*) OVER (), CAST(sum(g.records) OVER () AS bigint), g.sync_service_id, g.value,
         g.records, g.sample
  FROM (
    SELECT COALESCE(d.metadata->>'sync_service_id', '') AS sync_service_id,
           btrim(d.metadata->>'armis_device_id') AS value,
           count(*) AS records,
           (array_agg(d.uid ORDER BY d.uid))[1:5] AS sample
    FROM platform.ocsf_devices AS d
    WHERE d.deleted_at IS NULL AND d.source_retired_at IS NULL
      AND NULLIF(btrim(d.metadata->>'armis_device_id'), '') IS NOT NULL
      AND NOT (btrim(d.metadata->>'armis_device_id') = ANY (CAST($1 AS text[])))
    GROUP BY 1, 2
    HAVING count(*) > 1
  ) AS g
  ORDER BY g.records DESC, g.sync_service_id, g.value
  LIMIT $2
  """

  # V5: per source instance, the complete collections (`SyncRunLedger.complete/1`) whose first
  # chunk committed after $1, and whether its latest activated collection is one of them.
  @collections_after_sql """
  SELECT s.partition, s.source, s.source_instance, count(r.sync_run_id),
         COALESCE(bool_or(r.sync_run_id = s.collection_id), false)
  FROM platform.device_source_snapshots AS s
  LEFT JOIN (
    SELECT r.sync_service_id::text AS source_instance, r.sync_run_id
    FROM platform.sync_ingest_runs AS r
    WHERE r.inserted_at > CAST($1 AS timestamp)
      AND NOT r.incomplete AND r.total_chunks > 0
      AND r.received_chunks = ARRAY(SELECT generate_series(0, r.total_chunks - 1))
  ) AS r ON r.source_instance = s.source_instance
  GROUP BY s.partition, s.source, s.source_instance
  """

  # V5: the enabled sweep groups, per agent, that ran in the day before $1 and have completed no
  # cycle started after it. Execution times are stored to the second.
  @sweeps_waiting_sql """
  SELECT e.sweep_group_id::text, COALESCE(e.agent_id, '')
  FROM platform.sweep_group_executions AS e
  JOIN platform.sweep_groups AS g ON g.id = e.sweep_group_id
  WHERE g.enabled
    AND e.started_at >= CAST($1 AS timestamp) - interval '24 hours'
    AND e.started_at <= CAST($1 AS timestamp)
  EXCEPT
  SELECT e.sweep_group_id::text, COALESCE(e.agent_id, '')
  FROM platform.sweep_group_executions AS e
  WHERE e.status = 'completed'
    AND e.started_at >= date_trunc('second', CAST($1 AS timestamp)) + interval '1 second'
  ORDER BY 1, 2
  """

  # V6: the revivals since $2 of the records $1, apart from the rollback's ($3).
  @revivals_sql """
  SELECT count(*) OVER (), v.device_uid, v.revived_at, v.revived_by_application
  FROM platform.device_revival_audit AS v
  WHERE v.device_uid = ANY (CAST($1 AS text[]))
    AND v.revived_at >= CAST($2 AS timestamp)
    AND COALESCE(v.revived_by_application, '') <> CAST($3 AS text)
  ORDER BY v.revived_at, v.event_id
  LIMIT $4
  """

  # V7: the reconciliation runs started since $1, and how many started after $2. A run's row is
  # written when it finishes, as completed or failed.
  @reconciliation_runs_sql """
  SELECT count(*), count(*) FILTER (WHERE r.status = 'failed'),
         count(*) FILTER (WHERE COALESCE(r.errors, 0) > 0),
         CAST(COALESCE(sum(r.blocked_merges), 0) AS bigint),
         count(*) FILTER (WHERE r.started_at > CAST($2 AS timestamp)),
         max(r.started_at)
  FROM platform.identity_reconciliation_runs AS r
  WHERE r.started_at >= CAST($1 AS timestamp)
  """

  @latest_reconciliation_run_sql """
  SELECT r.status, COALESCE(r.errors, 0), COALESCE(r.blocked_merges, 0), r.started_at
  FROM platform.identity_reconciliation_runs AS r
  ORDER BY r.started_at DESC
  LIMIT 1
  """

  # V8: the retired and current ids of each source succession merge no unmerge has reversed.
  @succession_ids_sql """
  SELECT m.event_id::text, m.from_device_id, m.to_device_id, i.kind, i.value, i.partition
  FROM platform.merge_audit AS m
  CROSS JOIN LATERAL (
    SELECT 'retired', e->>'value', e->>'partition'
    FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(m.details->'retired_ids') = 'array'
        THEN m.details->'retired_ids' ELSE '[]'::jsonb END
    ) AS e
    UNION ALL
    SELECT 'current', e->>'value', e->>'partition'
    FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(m.details->'current_ids') = 'array'
        THEN m.details->'current_ids' ELSE '[]'::jsonb END
    ) AS e
  ) AS i (kind, value, partition)
  WHERE m.reason = 'source_succession'
    AND NOT EXISTS (
      SELECT 1 FROM platform.merge_audit AS u
      WHERE u.reason = 'unmerge' AND u.details->>'original_merge_event_id' = m.event_id::text
    )
  ORDER BY m.created_at, m.event_id
  """

  # V8: which of the values $5 the collection $4 of an instance reported present.
  @present_sql """
  SELECT o.source_object_id FROM platform.device_source_observations AS o
  WHERE o.partition = CAST($1 AS text) AND o.source = CAST($2 AS text)
    AND o.source_instance = CAST($3 AS text)
    AND o.collection_id = CAST($4 AS text) AND o.present
    AND o.source_object_id = ANY (CAST($5 AS text[]))
  """

  @doc false
  def run(_mode, opts, _manifest, actor) do
    with {:ok, settings} <- settings(actor),
         {:ok, window} <- window(Keyword.get(opts, :verify_manifests, [])) do
      checks = checks(settings, window, Keyword.get(opts, :reviewed_source_ids, []))

      %{
        checks: checks,
        verification_failures: Enum.count(checks, &(&1.result == :fail)),
        verification_pending: Enum.count(checks, &(&1.result == :pending)),
        verified_manifests: window.manifests,
        run_started_at: window.started_at,
        last_batch_finished_at: window.finished_at
      }
    else
      {:error, reason} -> %{errors: 1, error: inspect(reason)}
    end
  end

  @doc false
  # The `application_name` the rollback runs its restores and unmerges under, which the revival
  # audit records: V6 does not count those revivals.
  @spec rollback_application() :: String.t()
  def rollback_application, do: @rollback_application

  @doc false
  # The device cleanup settings the checks and the steps read N, T and the guard from.
  @spec settings(term()) :: {:ok, map()} | {:error, :settings_unavailable}
  def settings(actor) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} -> {:ok, settings}
      _other -> {:error, :settings_unavailable}
    end
  end

  @doc false
  # The source instances the checks judge and the steps act on, in order.
  @spec instances() :: [SourceRetirement.instance()]
  def instances do
    %{rows: rows} = Repo.query!(@instances_sql, [])

    for [partition, source, source_instance] <- rows,
        {:ok, _scope} <- [SourceAuthorityGuard.collection_scope(source, source_instance)] do
      %{partition: partition, source: source, source_instance: source_instance}
    end
  end

  @doc false
  # The device uids the entries of a manifest (`Manifest.read/1`) name: the records whose ids
  # retired, the records of each merge, and the records marked or tombstoned.
  @spec manifest_uids([map()]) :: [String.t()]
  def manifest_uids(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      named = entry |> Map.take(@uid_keys) |> Map.values()

      case entry do
        %{"table" => "platform.ocsf_devices", "ids" => ids} when is_list(ids) -> named ++ ids
        _other -> named
      end
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  # Class 8 (V3): the Armis ids carried in the metadata of more than one live, unmarked record of
  # one integration source, apart from the values `reviewed`, with the records holding them.
  @spec metadata_duplicates([String.t()]) :: %{
          groups: non_neg_integer(),
          records: non_neg_integer(),
          sample: [map()]
        }
  def metadata_duplicates(reviewed) do
    %{rows: rows} = Repo.query!(@metadata_duplicates_sql, [reviewed, @sample])

    case rows do
      [] ->
        %{groups: 0, records: 0, sample: []}

      [[groups, records | _rest] | _more] ->
        %{
          groups: groups,
          records: records,
          sample:
            Enum.map(rows, fn [_groups, _records, source, value, count, uids] ->
              %{sync_service_id: source, value: value, records: count, device_uids: uids}
            end)
        }
    end
  end

  @doc false
  # Class 7 (V4): the live released-seed shells, and the first `limit` of their uids.
  @spec released_seed_shells(pos_integer()) :: {non_neg_integer(), [String.t()]}
  def released_seed_shells(limit) when is_integer(limit) and limit > 0 do
    %{rows: rows} =
      Repo.query!(
        "SELECT count(*) OVER (), d.uid FROM platform.ocsf_devices AS d WHERE " <>
          PopulationGauges.released_seed_shell() <> " ORDER BY d.uid LIMIT $1",
        [limit]
      )

    case rows do
      [] -> {0, []}
      [[count, _uid] | _more] -> {count, Enum.map(rows, &List.last/1)}
    end
  end

  @doc false
  # V6, V7 and V8 as they read between the batches of a run started at `started_at` whose
  # manifest names the records `uids`: V7 waits only for a reconciliation run since the start.
  @spec harm_checks(map(), DateTime.t(), [String.t()]) :: [check()]
  def harm_checks(settings, %DateTime{} = started_at, uids) do
    [v6(started_at, uids), v7(started_at, started_at), v8(contexts(settings))]
  end

  @doc false
  # After a batch of `step` under `--execute`: records that the batch finished, then runs the
  # harm checks over the manifest so far. Returns `{:ok, checks}`, `{:halt, check, checks}` for
  # the first check that fails, or `{:error, reason}` when the manifest cannot be written or
  # read back.
  @spec finish_batch(Manifest.t(), String.t(), pos_integer(), map()) ::
          {:ok, [check()]} | {:halt, String.t(), [check()]} | {:error, term()}
  def finish_batch(%Manifest{} = manifest, step, batch, settings) do
    with :ok <- Manifest.record(manifest, step, :batch_finished, "none", [], %{batch: batch}),
         {:ok, _header, entries} <- Manifest.read(manifest.path) do
      checks = harm_checks(settings, manifest.started_at, manifest_uids(entries))

      case Enum.find(checks, &(&1.result == :fail)) do
        nil -> {:ok, checks}
        %{check: check} -> {:halt, check, checks}
      end
    end
  end

  defp checks(settings, window, reviewed) do
    contexts = contexts(settings)
    state = [v1(contexts), v2(contexts), v3(reviewed), v4()]

    state ++
      [
        v5(state, contexts, window.finished_at),
        v6(window.started_at, window.uids),
        v7(window.started_at, window.finished_at),
        v8(contexts)
      ]
  end

  defp contexts(settings) do
    now = DateTime.utc_now()
    Enum.map(instances(), &{&1, SourceRetirement.context(&1, settings: settings, now: now)})
  end

  defp window([]), do: {:ok, %{manifests: 0, started_at: nil, finished_at: nil, uids: []}}

  defp window(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, read} ->
      with {:ok, header, entries} <- Manifest.read(path),
           {:ok, started_at} <- Manifest.started_at(header) do
        {:cont, {:ok, [{started_at, entries} | read]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} ->
        starts = Enum.map(read, &elem(&1, 0))
        entries = Enum.flat_map(read, &elem(&1, 1))

        {:ok,
         %{
           manifests: length(read),
           started_at: Enum.min(starts, DateTime),
           finished_at: Enum.max(starts ++ entry_times(entries), DateTime),
           uids: manifest_uids(entries)
         }}

      {:error, _} = error ->
        error
    end
  end

  defp entry_times(entries) do
    Enum.flat_map(entries, fn
      %{"at" => at} when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, at, _offset} -> [at]
          _invalid -> []
        end

      _entry ->
        []
    end)
  end

  defp v1(contexts) do
    contexts
    |> Enum.map(fn
      {instance, {:ok, ctx}} ->
        %{live_records: live, current_ids: current} = SourceRetirement.population(ctx)
        unmarked = length(SourceRetirement.unmarked_retired(ctx, nil))
        holders = live + unmarked

        passes? =
          if current == 0, do: holders == 0, else: holders / current <= @max_live_to_current

        Map.merge(instance, %{
          result: if(passes?, do: :pass, else: :fail),
          live_records: live,
          unmarked_retired: unmarked,
          current_ids: current,
          ratio: Float.round(holders / max(current, 1), 4)
        })

      {instance, {:skip, reason}} ->
        Map.merge(instance, %{result: :pending, reason: reason})
    end)
    |> per_instance("V1", %{max_live_to_current: @max_live_to_current})
  end

  defp v2(contexts) do
    contexts
    |> Enum.map(fn
      {instance, {:ok, ctx}} ->
        rows = SourceRetirement.retirable(ctx, nil)

        Map.merge(instance, %{
          result: if(rows == [], do: :pass, else: :fail),
          retirable_ids: length(rows),
          records: rows |> Enum.uniq_by(& &1.device_id) |> length(),
          sample:
            rows
            |> Enum.take(@sample)
            |> Enum.map(&%{device_id: &1.device_id, value: &1.identifier_value})
        })

      {instance, {:skip, reason}} ->
        Map.merge(instance, %{result: :pending, reason: reason})
    end)
    |> per_instance("V2", %{})
  end

  defp v3(reviewed) do
    duplicates = metadata_duplicates(reviewed)

    %{
      check: "V3",
      result: if(duplicates.groups == 0, do: :pass, else: :fail),
      details: Map.put(duplicates, :reviewed_values, length(reviewed))
    }
  end

  defp v4 do
    {count, uids} = released_seed_shells(@sample)

    %{
      check: "V4",
      result: if(count == 0, do: :pass, else: :fail),
      details: %{live_shells: count, sample: uids}
    }
  end

  defp v5(_state, _contexts, nil),
    do: not_run("V5", "needs the run's manifest (--verify-manifest)")

  defp v5(state, contexts, %DateTime{} = finished_at) do
    scoped = MapSet.new(contexts, &elem(&1, 0))
    %{rows: rows} = Repo.query!(@collections_after_sql, [finished_at])

    collections =
      for [partition, source, source_instance, complete, latest] <- rows,
          MapSet.member?(scoped, %{
            partition: partition,
            source: source,
            source_instance: source_instance
          }) do
        %{
          partition: partition,
          source_instance: source_instance,
          complete_collections: complete,
          latest_collection_after: latest
        }
      end

    collections_waiting =
      Enum.reject(
        collections,
        &(&1.complete_collections >= @collections_after and
            &1.latest_collection_after)
      )

    %{rows: sweep_rows} = Repo.query!(@sweeps_waiting_sql, [finished_at])

    sweeps_waiting =
      Enum.map(sweep_rows, fn [group, agent] -> %{sweep_group_id: group, agent_id: agent} end)

    details = %{
      after: finished_at,
      collections: collections,
      collections_waiting: length(collections_waiting),
      sweeps_waiting: sweeps_waiting
    }

    if collections_waiting != [] or sweeps_waiting != [] do
      %{check: "V5", result: :pending, details: details}
    else
      judged = Enum.reject(state, &(&1.result == :not_run))

      %{
        check: "V5",
        result: combine(Enum.map(judged, & &1.result)),
        details:
          Map.put(details, :not_passing, for(%{result: r, check: c} <- judged, r != :pass, do: c))
      }
    end
  end

  defp v6(nil, _uids), do: not_run("V6", "needs the run's manifest (--verify-manifest)")
  defp v6(_started_at, []), do: %{check: "V6", result: :pass, details: %{records: 0, revived: 0}}

  defp v6(%DateTime{} = started_at, uids) do
    %{rows: rows} = Repo.query!(@revivals_sql, [uids, started_at, @rollback_application, @sample])

    revived =
      case rows do
        [] -> 0
        [[count | _rest] | _more] -> count
      end

    %{
      check: "V6",
      result: if(revived == 0, do: :pass, else: :fail),
      details: %{
        records: length(uids),
        revived: revived,
        sample:
          Enum.map(rows, fn [_count, uid, revived_at, application] ->
            %{device_uid: uid, revived_at: revived_at, application: application}
          end)
      }
    }
  end

  defp v7(nil, _finished_at) do
    case Repo.query!(@latest_reconciliation_run_sql, []).rows do
      [] ->
        %{check: "V7", result: :pending, details: %{reason: "no reconciliation run yet"}}

      [[status, errors, blocked, started_at]] ->
        %{
          check: "V7",
          result: if(status == "failed" or errors > 0, do: :fail, else: :pass),
          details: %{
            latest_run: started_at,
            status: status,
            errors: errors,
            blocked_merges: blocked
          }
        }
    end
  end

  defp v7(%DateTime{} = started_at, %DateTime{} = finished_at) do
    %{rows: [[runs, failed, errored, blocked, after_batch, latest]]} =
      Repo.query!(@reconciliation_runs_sql, [started_at, finished_at])

    result =
      cond do
        failed > 0 or errored > 0 -> :fail
        after_batch == 0 -> :pending
        true -> :pass
      end

    %{
      check: "V7",
      result: result,
      details: %{
        runs: runs,
        failed_runs: failed,
        runs_with_errors: errored,
        blocked_merges: blocked,
        runs_after_last_batch: after_batch,
        latest_run: latest
      }
    }
  end

  defp v8(contexts) do
    %{rows: rows} = Repo.query!(@succession_ids_sql, [])

    events =
      rows
      |> Enum.group_by(fn [event_id, merged, survivor | _ids] -> {event_id, merged, survivor} end)
      |> Enum.map(fn {{event_id, merged, survivor}, ids} ->
        %{
          event_id: event_id,
          merged: merged,
          survivor: survivor,
          ids:
            Enum.map(ids, fn [_event, _merged, _survivor, kind, value, partition] ->
              {kind, value, partition}
            end)
        }
      end)
      |> Enum.sort_by(& &1.event_id)

    {present, pending} = present_ids(events, contexts)

    judged =
      Enum.map(events, fn event ->
        reported = Enum.filter(event.ids, &MapSet.member?(present, {elem(&1, 1), elem(&1, 2)}))
        kinds = MapSet.new(reported, &elem(&1, 0))
        unjudged = Enum.any?(event.ids, &MapSet.member?(pending, elem(&1, 2)))

        result =
          cond do
            MapSet.subset?(MapSet.new(["retired", "current"]), kinds) -> :fail
            unjudged -> :pending
            true -> :pass
          end

        Map.put(event, :result, result)
      end)

    failing = Enum.filter(judged, &(&1.result == :fail))

    %{
      check: "V8",
      result: if(judged == [], do: :pass, else: combine(Enum.map(judged, & &1.result))),
      details: %{
        merges: length(judged),
        joined_present: length(failing),
        pending: Enum.count(judged, &(&1.result == :pending)),
        sample:
          failing
          |> Enum.take(@sample)
          |> Enum.map(&Map.take(&1, [:event_id, :merged, :survivor]))
      }
    }
  end

  # The `{value, partition}` pairs of the merges' ids that the latest exact collection of their
  # instance reports present, read in one statement per instance, and the identifier partitions
  # of the instances whose latest collection is not exact.
  defp present_ids([], _contexts), do: {MapSet.new(), MapSet.new()}

  defp present_ids(events, contexts) do
    ids = events |> Enum.flat_map(& &1.ids) |> Enum.uniq()

    Enum.reduce(contexts, {MapSet.new(), MapSet.new()}, fn {instance, context},
                                                           {present, pending} ->
      {:ok, scope} =
        SourceAuthorityGuard.collection_scope(instance.source, instance.source_instance)

      id_partition = instance.partition <> scope.partition_suffix
      scoped = Enum.filter(ids, fn {_kind, _value, partition} -> partition == id_partition end)
      partitions = MapSet.new(scoped, &elem(&1, 2))

      case {scoped, context} do
        {[], _context} ->
          {present, pending}

        {_scoped, {:skip, _reason}} ->
          {present, MapSet.union(pending, partitions)}

        {_scoped, {:ok, ctx}} ->
          values = scoped |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

          %{rows: rows} =
            Repo.query!(@present_sql, [
              instance.partition,
              instance.source,
              instance.source_instance,
              ctx.collection.collection_id,
              values
            ])

          reported = MapSet.new(rows, &hd/1)

          present =
            scoped
            |> Enum.filter(fn {_kind, value, _partition} -> MapSet.member?(reported, value) end)
            |> Enum.reduce(present, fn {_kind, value, partition}, acc ->
              MapSet.put(acc, {value, partition})
            end)

          {present, pending}
      end
    end)
  end

  defp per_instance([], name, details),
    do: %{
      check: name,
      result: :not_run,
      details: Map.put(details, :reason, "no scoped source instance")
    }

  defp per_instance(instances, name, details) do
    %{
      check: name,
      result: combine(Enum.map(instances, & &1.result)),
      details: Map.put(details, :instances, instances)
    }
  end

  defp not_run(name, reason), do: %{check: name, result: :not_run, details: %{reason: reason}}

  defp combine([]), do: :not_run

  defp combine(results) do
    cond do
      :fail in results -> :fail
      :pending in results -> :pending
      true -> :pass
    end
  end
end
