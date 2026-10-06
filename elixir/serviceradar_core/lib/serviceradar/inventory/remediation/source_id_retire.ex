defmodule ServiceRadar.Inventory.Remediation.SourceIdRetire do
  @moduledoc """
  Step `source-id-retire`: classes 1 and 5 of the source id remediation (change
  `add-source-id-succession`, design D11).

    * Class 1, a live record holding a retirable source id beside another source or agent id:
      the step retires the stale ids, and the record stays.
    * Class 5, a record already left holding only retired ids, unmarked because a release
      retired without marking, with no succession candidate: the step marks it
      `source_retired`, and `ServiceRadar.Inventory.SourceRetiredExpiry` deletes it after the
      grace period.

  The step retires through `SourceRetirement`, as a scheduled pass does: the same N, T, query
  hash and mass guard, and the same locks and rechecks, one transaction per record. It retires
  every id the rule admits, so a record the retirement leaves holding only retired ids is marked
  in the same transaction (design D5), and `source-succession` then merges it into its
  successor, if it has one. An instance the mass guard refuses is left alone, and counted in
  `mass_guard_failures`; one whose latest collection changes during the step is left at that
  point, and a re-run continues it.

  The dry run counts both classes per source instance, before any retirement. `--execute`
  requires retirement to be enabled in the device cleanup settings. It works in batches of
  `:source_batch_size` records (500 by default): each record's retirement or mark writes its
  manifest entry inside its transaction, and after each batch the harm checks run
  (`SourceIdVerification.finish_batch/4`). The step stops at the first check that fails, and
  at a manifest entry that cannot be written.
  """

  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.Identity.SourceSuccession
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.SourceIdVerification
  alias ServiceRadar.Repo

  require Logger

  @step "source-id-retire"
  @default_batch_size 500
  @sample 20

  # For each record of $1, how many ids of the marking types $3 it holds besides the rows $2
  # the rule would retire. A record left with none holds only retired ids once they retire.
  @kept_ids_sql """
  SELECT di.device_id,
         count(*) FILTER (WHERE NOT (di.id = ANY (CAST($2 AS bigint[]))))
  FROM platform.device_identifiers AS di
  WHERE di.device_id = ANY (CAST($1 AS text[]))
    AND di.identifier_type = ANY (CAST($3 AS text[]))
  GROUP BY di.device_id
  """

  @doc false
  def run(mode, opts, manifest, actor) do
    case SourceIdVerification.settings(actor) do
      {:ok, settings} -> run(mode, opts, manifest, actor, settings)
      {:error, reason} -> %{errors: 1, error: inspect(reason)}
    end
  end

  defp run(:dry_run, _opts, _manifest, actor, settings) do
    contexts =
      Enum.map(SourceIdVerification.instances(), fn instance ->
        {instance, SourceRetirement.context(instance, settings: settings, actor: actor)}
      end)

    plans = Enum.map(contexts, &plan_instance(&1, settings))
    rows = Enum.flat_map(plans, &Map.get(&1, :rows, []))
    records = rows |> Enum.map(& &1.device_id) |> Enum.uniq()
    kept = kept_ids(records, rows)
    class_1 = Enum.count(records, &(Map.get(kept, &1, 0) > 0))
    class_5 = class_5(contexts, plan_uids(SourceSuccession.plan(actor: actor)))

    %{
      source_retirement_enabled: settings.source_retirement_enabled,
      guard_override: settings.source_retirement_guard_override,
      would_retire_ids: length(rows),
      would_retire_records: length(records),
      class_1_records: class_1,
      would_leave_retired_only: length(records) - class_1,
      guard_would_refuse: Enum.count(plans, &match?(%{guard: %{verdict: :refuse}}, &1)),
      class_5_records: length(class_5),
      retire_sample: rows |> Enum.take(@sample) |> Enum.map(&sample_row/1),
      class_5_sample: Enum.take(class_5, @sample),
      instance_plans: Enum.map(plans, &Map.delete(&1, :rows))
    }
  end

  defp run(:execute, opts, manifest, actor, settings) do
    if settings.source_retirement_enabled == true do
      case Manifest.ensure_writable(manifest) do
        :ok -> execute(opts, manifest, actor, settings)
        {:error, reason} -> %{manifest_failures: 1, halted: "manifest", error: inspect(reason)}
      end
    else
      %{
        execution_blocked: true,
        execution_blocked_reason: "source_retirement_disabled",
        halted: "source_retirement_disabled"
      }
    end
  end

  defp plan_instance({instance, {:skip, reason}}, _settings),
    do: Map.put(instance, :status, reason)

  defp plan_instance({instance, {:ok, ctx}}, settings) do
    rows = SourceRetirement.retirable(ctx, nil)

    Map.merge(instance, %{
      status: :ready,
      collection_id: ctx.collection.collection_id,
      would_retire_ids: length(rows),
      would_retire_records: rows |> Enum.uniq_by(& &1.device_id) |> length(),
      guard: guard(rows, settings, ctx),
      rows: rows
    })
  end

  defp guard(rows, settings, ctx) do
    case SourceRetirement.guard(rows, settings, ctx) do
      {:allow, counts} -> Map.put(counts, :verdict, :allow)
      {:refuse, reason, counts} -> Map.merge(counts, %{verdict: :refuse, reason: reason})
    end
  end

  defp kept_ids([], _rows), do: %{}

  defp kept_ids(records, rows) do
    types = Enum.map(SourceRetirement.marking_identifier_types(), &Atom.to_string/1)
    %{rows: kept} = Repo.query!(@kept_ids_sql, [records, Enum.map(rows, & &1.id), types])
    Map.new(kept, fn [device_id, count] -> {device_id, count} end)
  end

  # The unmarked retired-only records of the instances, apart from those a succession merges or
  # sends to review (`excluded`), which have a candidate.
  defp class_5(contexts, excluded) do
    contexts
    |> Enum.flat_map(fn
      {_instance, {:ok, ctx}} -> SourceRetirement.unmarked_retired(ctx, nil)
      {_instance, {:skip, _reason}} -> []
    end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(excluded, &1))
    |> Enum.sort()
  end

  defp plan_uids(%{successive: pairs, reviews: reviews}) do
    MapSet.new(
      Enum.flat_map(pairs, &[&1.predecessor, &1.successor]) ++
        Enum.flat_map(reviews, & &1.device_uids)
    )
  end

  defp sample_row(row), do: %{device_id: row.device_id, value: row.identifier_value}

  defp execute(opts, manifest, actor, settings) do
    run = %{
      manifest: manifest,
      actor: actor,
      settings: settings,
      batch_size: Keyword.get(opts, :source_batch_size, @default_batch_size),
      manifest_errors: :counters.new(1, [])
    }

    instances = SourceIdVerification.instances()

    {state, plans} =
      Enum.reduce(instances, {initial_state(), []}, fn instance, {state, plans} ->
        if state.halted do
          {state, [Map.put(instance, :status, :not_run) | plans]}
        else
          {state, plan} = retire_instance(instance, state, run)
          {state, [plan | plans]}
        end
      end)

    plans = Enum.reverse(plans)
    state = if state.halted, do: state, else: mark_class_5(instances, plans, state, run)

    state
    |> Map.put(:instance_plans, plans)
    |> then(&if(&1.halted, do: &1, else: Map.delete(&1, :halted)))
  end

  defp initial_state do
    %{
      retired_ids: 0,
      retired_records: 0,
      marked_at_retirement: 0,
      skipped: 0,
      retire_failures: 0,
      manifest_failures: 0,
      mass_guard_failures: 0,
      class_5_marked: 0,
      class_5_not_marked: 0,
      mark_failures: 0,
      batches: 0,
      harm_check_failures: 0,
      checks: [],
      halted: nil
    }
  end

  defp retire_instance(instance, state, run) do
    on_retired = &record_retirement(&1, run)
    opts = [settings: run.settings, actor: run.actor, on_retired: on_retired]

    with {:ok, ctx} <- SourceRetirement.context(instance, opts),
         [_ | _] = rows <- SourceRetirement.retirable(ctx, nil),
         :ok <- SourceRetirement.admit(rows, run.settings, ctx) do
      plan =
        Map.merge(instance, %{
          status: :retired,
          collection_id: ctx.collection.collection_id,
          retired_ids: 0,
          retired_records: 0
        })

      rows
      |> Enum.group_by(& &1.device_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(run.batch_size)
      |> Enum.reduce_while({state, plan}, fn chunk, {state, plan} ->
        retire_batch(Enum.flat_map(chunk, &elem(&1, 1)), ctx, state, plan, run)
      end)
    else
      {:skip, reason} ->
        {state, Map.put(instance, :status, reason)}

      [] ->
        {state, Map.put(instance, :status, :nothing_to_retire)}

      {:error, reason} ->
        {%{state | mass_guard_failures: state.mass_guard_failures + 1},
         Map.merge(instance, %{status: :mass_guard_refused, guard: refusal(reason)})}
    end
  end

  defp refusal({:mass_retirement_refused, counts}), do: counts
  defp refusal(reason), do: %{reason: inspect(reason)}

  defp retire_batch(rows, ctx, state, plan, run) do
    if collection_unchanged?(ctx, run) do
      before = :counters.get(run.manifest_errors, 1)
      stats = SourceRetirement.retire(rows, ctx)
      manifest_failed = :counters.get(run.manifest_errors, 1) - before

      state = %{
        state
        | retired_ids: state.retired_ids + stats.retired,
          retired_records: state.retired_records + stats.devices,
          marked_at_retirement: state.marked_at_retirement + stats.marked,
          skipped: state.skipped + stats.skipped,
          retire_failures: state.retire_failures + stats.failed - manifest_failed,
          manifest_failures: state.manifest_failures + manifest_failed
      }

      plan = %{
        plan
        | retired_ids: plan.retired_ids + stats.retired,
          retired_records: plan.retired_records + stats.devices
      }

      state =
        if manifest_failed > 0, do: %{state | halted: "manifest"}, else: finish_batch(state, run)

      if state.halted, do: {:halt, {state, plan}}, else: {:cont, {state, plan}}
    else
      {:halt, {state, %{plan | status: :collection_changed}}}
    end
  end

  # A pass retires only under the collection its context read: once another activates, every
  # record of the instance would be skipped under the lock, so the step leaves the instance.
  defp collection_unchanged?(ctx, run) do
    case SourceRetirement.context(ctx.instance, settings: run.settings) do
      {:ok, %{collection: collection}} ->
        collection.collection_id == ctx.collection.collection_id and
          collection.activated_at == ctx.collection.activated_at

      {:skip, _reason} ->
        false
    end
  end

  # Class 5, once the retirements are done: the plan is read again, since they can make a
  # record a predecessor. An instance the mass guard refused is left alone.
  defp mark_class_5(instances, plans, state, run) do
    refused =
      for %{status: :mass_guard_refused} = plan <- plans,
          into: MapSet.new(),
          do: Map.take(plan, [:partition, :source, :source_instance])

    excluded = plan_uids(SourceSuccession.plan(actor: run.actor))
    opts = [settings: run.settings, actor: run.actor, on_marked: &record_mark(&1, run)]

    instances
    |> Enum.reject(&MapSet.member?(refused, &1))
    |> Enum.reduce_while(state, fn instance, state ->
      case SourceRetirement.context(instance, opts) do
        {:ok, ctx} ->
          ctx
          |> SourceRetirement.unmarked_retired(nil)
          |> Enum.reject(&MapSet.member?(excluded, &1))
          |> Enum.chunk_every(run.batch_size)
          |> Enum.reduce_while(state, &mark_batch(&1, ctx, &2, run))
          |> then(&if(&1.halted, do: {:halt, &1}, else: {:cont, &1}))

        {:skip, _reason} ->
          {:cont, state}
      end
    end)
  end

  defp mark_batch(uids, ctx, state, run) do
    state =
      Enum.reduce_while(uids, state, fn uid, state ->
        before = :counters.get(run.manifest_errors, 1)

        case SourceRetirement.mark_unmarked_retired(uid, ctx) do
          {:ok, :not_marked} ->
            {:cont, %{state | class_5_not_marked: state.class_5_not_marked + 1}}

          {:ok, %{}} ->
            {:cont, %{state | class_5_marked: state.class_5_marked + 1}}

          {:error, reason} ->
            if :counters.get(run.manifest_errors, 1) > before do
              {:halt,
               %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
            else
              Logger.warning("#{@step}: could not mark #{uid} source_retired: #{inspect(reason)}")
              {:cont, %{state | mark_failures: state.mark_failures + 1}}
            end
        end
      end)

    state = if state.halted, do: state, else: finish_batch(state, run)
    if state.halted, do: {:halt, state}, else: {:cont, state}
  end

  defp finish_batch(state, run) do
    batch = state.batches + 1

    case SourceIdVerification.finish_batch(run.manifest, @step, batch, run.settings) do
      {:ok, checks} ->
        %{state | batches: batch, checks: checks}

      {:halt, check, checks} ->
        Logger.error("#{@step}: check #{check} failed after batch #{batch}; stopping")

        %{
          state
          | batches: batch,
            checks: checks,
            halted: check,
            harm_check_failures: state.harm_check_failures + 1
        }

      {:error, reason} ->
        Logger.error("#{@step}: batch #{batch} could not be recorded: #{inspect(reason)}")

        %{
          state
          | batches: batch,
            manifest_failures: state.manifest_failures + 1,
            halted: "manifest"
        }
    end
  end

  # The manifest entries, written inside the record's transaction: an entry that cannot be
  # written rolls the retirement or mark back.
  defp record_retirement(event, run) do
    instance = event.instance
    ids = Enum.flat_map(event.rows, fn row -> [row.id | Enum.map(row.accompanying, & &1.id)] end)

    record(run, "retire_source_ids", "platform.device_identifier_archive", ids, %{
      device_id: event.device_id,
      partition: instance.partition,
      source: instance.source,
      source_instance: instance.source_instance,
      primary_ids: Enum.map(event.rows, & &1.id),
      marked: event.marked,
      marked_at: iso8601(event.marked_at),
      prior_identity_state: event.prior_identity_state
    })
  end

  defp record_mark(event, run) do
    instance = event.instance

    record(run, "mark_source_retired", "platform.ocsf_devices", [event.device_id], %{
      partition: instance.partition,
      source: instance.source,
      source_instance: instance.source_instance,
      marked_at: iso8601(event.marked_at),
      prior_identity_state: event.prior_identity_state
    })
  end

  defp record(run, action, table, ids, extra) do
    case Manifest.record(run.manifest, @step, action, table, ids, extra) do
      :ok ->
        :ok

      {:error, reason} ->
        :counters.add(run.manifest_errors, 1, 1)
        Logger.error("#{@step}: failed to record #{action} in the manifest: #{inspect(reason)}")
        {:error, {:manifest_failed, reason}}
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)
end
