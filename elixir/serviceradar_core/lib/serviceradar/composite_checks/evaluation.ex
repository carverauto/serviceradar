defmodule ServiceRadar.CompositeChecks.Evaluation do
  @moduledoc """
  Runs evaluation passes for a composite check.

  There are two passes over one evaluation and one persistence path:

    * the **full pass** (`run_full/2`, `run/2`) walks the whole scope. It is the
      only pass that notices an input aging past `max_age`, a device entering
      or leaving scope, or a metadata key with no provenance timestamp: none of
      those writes a row. It must never be removed in favour of the
      incremental pass.
    * the **incremental pass** (`run_incremental/2`) re-evaluates only the
      in-scope devices whose input rows were written after the check's
      `last_incremental_at` mark, less `@watermark_slack_seconds`. It is what
      makes a verdict follow a sweep result within a minute without any work
      in sweep ingestion.

  The mark is the database `now()` taken *before* the dirty read. Both
  dirty-row writers stamp `updated_at` with `now()` inside one short statement
  (the sweep ingestor's availability upsert, and the fact write's provenance),
  and `now()` is the statement's transaction start. A writer whose transaction
  opened before the mark therefore commits within the slack and is selected by
  the next pass; re-evaluating a device inside the overlap is idempotent.

  Each page is written with one multi-row upsert and, for a check that owns
  canonical availability, at most two set-based updates. Only devices that are
  live when their page is loaded (`deleted_at` nil) are evaluated or written.

  Per page of the scope, exactly one availability query and one device-metadata
  query are issued; resolution and evaluation happen in memory, because the
  resolvers and the evaluator are pure. That is what keeps a pass over a large
  scope from becoming an N+1.

  Scope exit is handled by mark-and-sweep rather than by diffing UID sets: every
  row written in a pass carries the pass start time in `evaluated_at`, and rows
  older than that at the end of the pass belonged to devices that are no longer
  in scope. Memory stays bounded no matter how large the scope is.

  A pass that did not complete never sweeps. Un-evaluated rows keep an older
  `evaluated_at` and would be indistinguishable from devices that left the
  scope, so sweeping after a partial failure would delete verdicts for devices
  that are still perfectly in scope. This is enforced by letting the failure
  propagate: `Scope.stream_uids/2` raises on a query error, so `run/2` never
  reaches the sweep and Oban retries the pass. Do not "improve" this by
  rescuing mid-pass and continuing — the sweep would then run against a partial
  evaluation and delete live verdicts.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluator
  alias ServiceRadar.CompositeChecks.Resolvers
  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.CompositeChecks.VerdictEventWriter
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Repo

  require Logger

  @type transition :: %{
          device_uid: String.t(),
          check_id: Ash.UUID.t(),
          from_verdict: String.t() | nil,
          to_verdict: String.t(),
          from_status: atom() | nil,
          to_status: atom(),
          inputs: map()
        }

  @type summary :: %{
          evaluated: non_neg_integer(),
          transitions: [transition()],
          removed: non_neg_integer()
        }

  @watermark_slack_seconds 120

  @doc "How far before the stored mark the incremental dirty read looks back."
  def watermark_slack_seconds, do: @watermark_slack_seconds

  @doc """
  Runs the full pass and, on success, records both marks.

  `last_incremental_at` becomes the database `now()` taken before the scope is
  read; `last_evaluated_at` becomes `now()` at successful completion, so a pass
  that runs longer than the interval is not due again on the next tick. A
  failed pass records nothing.
  """
  @spec run_full(struct(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run_full(check, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    mark = db_now()

    with {:ok, summary} <- run(check, Keyword.put(opts, :now, mark)),
         {:ok, _check} <-
           record_marks(check, %{last_incremental_at: mark, last_evaluated_at: db_now()}, actor) do
      {:ok, summary}
    end
  end

  @doc """
  Re-evaluates the in-scope devices whose inputs changed since the check's
  `last_incremental_at` mark (less the slack), and on success advances the mark
  to the database `now()` taken before the dirty read, including when nothing
  was selected.

  Never sweeps out-of-scope rows and never advances `last_evaluated_at`. A
  check with no mark has no defined dirty set; the caller runs the full pass.
  """
  @spec run_incremental(struct(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run_incremental(%{last_incremental_at: nil}, _opts), do: {:error, :no_incremental_mark}

  def run_incremental(check, opts) do
    actor = Keyword.fetch!(opts, :actor)
    mark = db_now()
    since = DateTime.shift(check.last_incremental_at, second: -@watermark_slack_seconds)
    opts = Keyword.put(opts, :now, mark)

    with {:ok, normalized} <- Scope.normalize(check.scope_query),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(check.id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(check.id, actor: actor),
         {:ok, evaluated, transitions} <-
           run_dirty_pages(check, normalized, inputs, rules, since, mark, opts),
         {:ok, _check} <- record_marks(check, %{last_incremental_at: mark}, actor) do
      if Keyword.get(opts, :emit_events?, true) do
        VerdictEventWriter.write_transitions(check, transitions)
      end

      {:ok, %{evaluated: evaluated, transitions: transitions, removed: 0}}
    end
  end

  defp run_dirty_pages(check, normalized, inputs, rules, since, mark, opts) do
    check
    |> dirty_uids(inputs, since)
    |> Enum.reduce_while({:ok, 0, []}, fn page, {:ok, count, acc} ->
      case Scope.contains?(normalized, page, opts) do
        {:ok, in_scope} ->
          uids = Enum.filter(page, &MapSet.member?(in_scope, &1))
          {:ok, rows} = evaluate_devices(check, inputs, rules, uids, opts)
          persist_canonical_availability(check, rows)
          {:cont, {:ok, count + length(rows), [persist_page(check, rows, mark) | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:scope_query_failed, reason}}}
      end
    end)
    |> case do
      {:ok, count, reversed} -> {:ok, count, reversed |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  @doc """
  Pages of the device uids whose inputs for `check` were written after `since`.

  A device is dirty when a `device_agent_availability` row for one of the
  check's vantage-point agents has `updated_at > since`, or, for a check with
  `:device_metadata` inputs, when a configured path's
  `metadata['__fact_provenance'][path]['updated_at']` is later than `since`.
  `ocsf_devices.modified_time` is never read: sweep status writes and
  `set_availability` touch it without changing any input. Pages hold at most
  `Scope.dirty_page_limit/0` uids, sorted, so each fits one SRQL list filter.
  """
  @spec dirty_uids(struct(), [struct()], DateTime.t()) :: [[String.t()]]
  def dirty_uids(_check, inputs, since) do
    inputs
    |> vantage_agent_ids()
    |> availability_uids(since)
    |> Enum.concat(provenance_uids(metadata_paths(inputs), since))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(Scope.dirty_page_limit())
  end

  defp availability_uids([], _since), do: []

  defp availability_uids(agent_ids, since) do
    DeviceAgentAvailability
    |> where([a], a.agent_id in ^agent_ids and a.updated_at > ^since)
    |> distinct(true)
    |> select([a], a.device_uid)
    |> Repo.all()
  end

  defp provenance_uids([], _since), do: []

  # The provenance timestamp is an ISO-8601 string written by the fact API. The
  # shape guard keeps one malformed value from failing the cast for the whole
  # dirty read.
  defp provenance_uids(paths, since) do
    Device
    |> where([d], is_nil(d.deleted_at))
    |> where(
      [d],
      fragment(
        """
        EXISTS (
          SELECT 1 FROM unnest(?::text[]) AS p(path)
          WHERE CASE
            WHEN (? -> '__fact_provenance' -> p.path ->> 'updated_at')
                 ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
            THEN (? -> '__fact_provenance' -> p.path ->> 'updated_at')::timestamptz > ?
            ELSE false
          END
        )
        """,
        ^paths,
        d.metadata,
        d.metadata,
        ^since
      )
    )
    |> select([d], d.uid)
    |> Repo.all()
  end

  defp vantage_agent_ids(inputs) do
    inputs
    |> Enum.filter(&(&1.kind == :vantage_point))
    |> Enum.map(&Map.get(&1.config, "agent_id"))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp metadata_paths(inputs) do
    inputs
    |> Enum.filter(&(&1.kind == :device_metadata))
    |> Enum.map(&Map.get(&1.config, "path"))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp record_marks(check, marks, actor) do
    CompositeCheck.record_pass(check, marks, actor: actor)
  end

  @doc false
  # The database clock, so marks and the rows they are compared against share
  # one clock.
  def db_now do
    %{rows: [[now]]} = Repo.query!("SELECT now()")
    DateTime.truncate(now, :microsecond)
  end

  @doc """
  Runs one full evaluation pass without recording marks.

  `run_full/2` is the scheduled entry point; this is the pass itself, reused by
  tests and callers that must not move the schedule.
  """
  @spec run(struct(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(check, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    started_at = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- Scope.normalize(check.scope_query),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(check.id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(check.id, actor: actor) do
      {evaluated, transitions} =
        run_pages(check, normalized, inputs, rules, started_at, opts)

      # Only reached when every page succeeded; a page failure raises out of
      # run_pages/7 above and leaves existing verdicts untouched.
      removed = sweep_out_of_scope(check, started_at)

      # Opt-out exists so the authoring preview can reuse the pass without
      # polluting the event stream. Defaults on, so production needs no opt-in.
      if Keyword.get(opts, :emit_events?, true) do
        VerdictEventWriter.write_transitions(check, transitions)
      end

      {:ok, %{evaluated: evaluated, transitions: transitions, removed: removed}}
    end
  end

  defp run_pages(check, normalized, inputs, rules, started_at, opts) do
    {count, reversed} =
      normalized
      |> Scope.stream_uids(opts)
      |> Enum.reduce({0, []}, fn uids, {count, acc} ->
        {:ok, rows} = evaluate_devices(check, inputs, rules, uids, opts)
        persist_canonical_availability(check, rows)
        {count + length(rows), [persist_page(check, rows, started_at) | acc]}
      end)

    {count, reversed |> Enum.reverse() |> List.flatten()}
  end

  @doc """
  Resolves inputs and evaluates verdicts for a set of device UIDs without
  persisting anything.

  The authoring preview calls this directly, which is what guarantees preview
  and production cannot disagree.
  """
  @spec evaluate_devices(struct(), [struct()], [struct()], [String.t()], keyword()) ::
          {:ok, [map()]}
  def evaluate_devices(check, inputs, rules, uids, opts \\ [])

  def evaluate_devices(_check, _inputs, _rules, [], _opts), do: {:ok, []}

  def evaluate_devices(check, inputs, rules, uids, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    # Unconditional: this load is also the liveness filter. A uid that was
    # deleted or merged away since it was selected is absent here and gets no
    # row, so it is neither written nor reported as a transition.
    metadata = load_live_devices(uids)
    uids = Enum.filter(uids, &Map.has_key?(metadata, &1))
    availability = load_availability(inputs, uids)

    rows =
      Enum.map(uids, fn uid ->
        resolutions = resolve_inputs(inputs, uid, availability, metadata, now)
        resolutions = validation_resolutions(resolutions, inputs, uid, opts)
        values = Map.new(resolutions, fn {key, resolution} -> {key, resolution.value} end)

        {verdict, status, matched_rule_id} =
          if not_probed?(resolutions, inputs, opts) do
            {"not_probed", :unknown, nil}
          else
            decide(check, uid, values, rules)
          end

        %{
          device_uid: uid,
          verdict: verdict,
          status: status,
          matched_rule_id: matched_rule_id,
          inputs: snapshot(resolutions)
        }
      end)

    {:ok, rows}
  end

  defp validation_resolutions(resolutions, inputs, uid, opts) do
    case Keyword.fetch(opts, :validation_coverage) do
      :error ->
        resolutions

      {:ok, coverage} ->
        inputs
        |> Enum.filter(&(&1.kind == :vantage_point))
        |> Enum.reduce(resolutions, fn input, acc ->
          meta = get_in(coverage, [uid, input.config["agent_id"]]) || %{}
          Map.put(acc, input.key, validation_observation(meta))
        end)
    end
  end

  defp validation_observation(meta) do
    observed_at = observation_time(meta["observed_at"])

    observed? =
      meta["state"] == "observed" and is_boolean(meta["is_available"]) and not is_nil(observed_at)

    value =
      cond do
        not observed? -> :unknown
        meta["is_available"] -> :available
        true -> :blocked
      end

    %{
      value: value,
      observed_at: if(observed?, do: observed_at),
      stale: false,
      reason: if(observed?, do: nil, else: meta["reason"] || meta["state"] || "no_probe"),
      covered: meta["state"] not in [nil, "uncovered", "skipped"],
      probed: observed?
    }
  end

  defp observation_time(nil), do: nil

  defp observation_time(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp not_probed?(resolutions, inputs, opts) do
    if Keyword.has_key?(opts, :validation_coverage) do
      vantages = Enum.filter(inputs, &(&1.kind == :vantage_point))
      vantages == [] or Enum.any?(vantages, &(not resolutions[&1.key].probed))
    else
      false
    end
  end

  defp decide(check, uid, values, rules) do
    case Evaluator.verdict(values, rules) do
      {:ok, decision} ->
        {decision.verdict, decision.status, decision.matched_rule_id}

      {:error, :no_matching_rule} ->
        Logger.warning("composite check has no matching rule and no catch-all",
          check_id: check.id,
          device_uid: uid
        )

        {"inconclusive", :unknown, nil}
    end
  end

  defp resolve_inputs(inputs, uid, availability, metadata, now) do
    Map.new(inputs, fn input ->
      resolution =
        case input.kind do
          :vantage_point ->
            agent_id = Map.get(input.config, "agent_id")
            row = availability |> Map.get(uid, %{}) |> Map.get(agent_id)
            Resolvers.VantagePoint.resolve(input, row, now)

          :device_metadata ->
            Resolvers.DeviceMetadata.resolve(input, Map.get(metadata, uid, %{}), now)
        end

      {input.key, resolution}
    end)
  end

  defp snapshot(resolutions) do
    Map.new(resolutions, fn {key, resolution} ->
      {key,
       Map.merge(
         %{
           "value" => to_string(resolution.value),
           "observed_at" => resolution.observed_at && DateTime.to_iso8601(resolution.observed_at),
           "stale" => resolution.stale,
           "reason" => resolution.reason && to_string(resolution.reason)
         },
         resolution
         |> Map.take([:covered, :probed])
         |> Map.new(fn {key, value} -> {to_string(key), value} end)
       )}
    end)
  end

  defp load_availability(_inputs, []), do: %{}

  defp load_availability(inputs, uids) do
    agent_ids = vantage_agent_ids(inputs)

    if agent_ids == [] do
      %{}
    else
      DeviceAgentAvailability
      |> where([r], r.device_uid in ^uids and r.agent_id in ^agent_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.device_uid)
      |> Map.new(fn {uid, rows} -> {uid, Map.new(rows, &{&1.agent_id, &1})} end)
    end
  end

  defp load_live_devices([]), do: %{}

  defp load_live_devices(uids) do
    Device
    |> where([d], d.uid in ^uids and is_nil(d.deleted_at))
    |> select([d], {d.uid, d.metadata})
    |> Repo.all()
    |> Map.new(fn {uid, metadata} -> {uid, metadata || %{}} end)
  end

  # The bulk form of Device.set_availability: is_available (and the
  # modified_time that action stamps), one statement per direction, and only
  # where the bit actually changes. :degraded and :unknown leave it alone. This
  # is deliberately not the sweep ingestor's reporter-scoped update, which would
  # match nothing here and would rewrite last_seen_time and sweep metadata.
  defp persist_canonical_availability(%{write_canonical_availability: true}, rows) do
    healthy = for %{status: :healthy, device_uid: uid} <- rows, do: uid
    down = for %{status: :down, device_uid: uid} <- rows, do: uid

    DevicePubSub.broadcast_invalidated(
      set_canonical_availability(healthy, true) ++ set_canonical_availability(down, false)
    )
  end

  defp persist_canonical_availability(_check, _rows), do: :ok

  defp set_canonical_availability([], _available?), do: []

  defp set_canonical_availability(uids, available?) do
    {_count, changed} =
      Device
      |> where([d], d.uid in ^uids and is_nil(d.deleted_at))
      |> where([d], d.is_available != ^available? or is_nil(d.is_available))
      |> select([d], d.uid)
      |> Repo.update_all(
        set: [
          is_available: available?,
          modified_time: DateTime.truncate(DateTime.utc_now(), :second)
        ]
      )

    changed
  end

  # Transitions are computed in memory against the prior rows exactly as
  # before; only the write is set-based: one multi-row upsert per page.
  defp persist_page(_check, [], _evaluated_at), do: []

  defp persist_page(check, rows, evaluated_at) do
    existing = load_existing(check, rows)
    now = DateTime.utc_now()

    {records, transitions} =
      Enum.map_reduce(rows, [], fn row, acc ->
        prior = Map.get(existing, row.device_uid)
        changed? = is_nil(prior) or prior.verdict != row.verdict
        changed_at = if changed?, do: evaluated_at, else: prior.changed_at

        record = %{
          id: Ash.UUID.generate(),
          device_uid: row.device_uid,
          check_id: check.id,
          verdict: row.verdict,
          status: row.status,
          matched_rule_id: row.matched_rule_id,
          inputs: row.inputs,
          evaluated_at: evaluated_at,
          changed_at: changed_at,
          inserted_at: now,
          updated_at: now
        }

        {record, if(changed?, do: [transition(check, row, prior) | acc], else: acc)}
      end)

    Repo.insert_all(DeviceCompositeCheckResult, records,
      on_conflict:
        {:replace,
         [:verdict, :status, :matched_rule_id, :inputs, :evaluated_at, :changed_at, :updated_at]},
      conflict_target: [:device_uid, :check_id]
    )

    Enum.reverse(transitions)
  end

  defp load_existing(_check, []), do: %{}

  defp load_existing(check, rows) do
    uids = Enum.map(rows, & &1.device_uid)

    DeviceCompositeCheckResult
    |> where([r], r.check_id == ^check.id and r.device_uid in ^uids)
    |> Repo.all()
    |> Map.new(&{&1.device_uid, &1})
  end

  defp transition(check, row, prior) do
    %{
      device_uid: row.device_uid,
      check_id: check.id,
      from_verdict: prior && prior.verdict,
      to_verdict: row.verdict,
      from_status: prior && prior.status,
      to_status: row.status,
      inputs: row.inputs
    }
  end

  defp sweep_out_of_scope(check, started_at) do
    {count, _} =
      DeviceCompositeCheckResult
      |> where([r], r.check_id == ^check.id and r.evaluated_at < ^started_at)
      |> Repo.delete_all()

    count
  end
end
