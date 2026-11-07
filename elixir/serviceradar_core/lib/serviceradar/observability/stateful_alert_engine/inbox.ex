defmodule ServiceRadar.Observability.StatefulAlertEngine.Inbox do
  @moduledoc """
  Bounded, ordered durable admission for stateful alert evaluation.

  Admission never makes a batch unadmittable because of its own size. Records
  are admitted `batch_records` at a time, one short transaction each, and every
  rule takes the longest in-order prefix of its occurrences that fits its own
  budget and the shared pending budget. Whatever does not fit stays unadmitted
  and the call answers `{:error, {:overloaded, dimension}}`; accepted
  occurrences are replay-safe, so retrying the same records admits exactly the
  remainder, still in order, once evaluation has drained capacity.

  An occurrence that alone exceeds `rule_bytes` or `pending_bytes` can never
  fit. It is skipped, counted as `:record_too_large` and logged, never
  truncated: callers persist the record itself before admitting it. The skip
  commits a `:cancelled` receipt, so a redelivery treats it as a replay and
  counts and logs it once.

  The admission mutex only covers capacity, replay lookup and committed input
  order. Evaluators use a different fence and never acquire this mutex, so a
  slow rule cannot delay admission for another rule. Accepted rows have no TTL.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.NotificationQueue
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.AlertEvaluationLane, as: Lane
  alias ServiceRadar.Observability.AlertEvaluationReceipt, as: Receipt
  alias ServiceRadar.Observability.AlertEvaluationWork, as: Work
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.Input
  alias ServiceRadar.Observability.StatefulAlertEngine.Record
  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher
  alias ServiceRadar.Observability.StatefulAlertEngine.RuntimeMetrics
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @defaults %{
    admission_timeout_ms: 2_000,
    batch_records: 500,
    batch_work: 5_000,
    pending_count: 50_000,
    pending_bytes: 64 * 1_024 * 1_024,
    rule_count: 5_000,
    rule_bytes: 8 * 1_024 * 1_024
  }
  @admission_key "alert-evaluation:admission:v1"
  @client_backstop_multiplier 10
  @min_client_timeout_ms 10_000

  @doc """
  Admits every eligible rule occurrence of `records` that capacity allows, in
  input order. `{:ok, keys}` means every occurrence is accepted (or was skipped
  as too large to ever fit); `{:error, {:overloaded, dimension}}` means a prefix
  may be accepted and a retry of the same records continues after it.
  """
  def admit(signal, records) when signal in [:log, :event, :metric] and is_list(records) do
    limits = limits()

    records
    |> Enum.chunk_every(limits.batch_records)
    |> Enum.reduce_while({:ok, []}, fn slice, {:ok, keys} ->
      case admit_slice(signal, slice, limits) do
        {:ok, slice_keys} -> {:cont, {:ok, keys ++ slice_keys}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def admit(_signal, _records), do: {:error, :invalid_payload}

  defp admit_slice(signal, records, limits) do
    started = System.monotonic_time(:millisecond)

    result =
      with :ok <- Rollout.admission_ready(),
           {:ok, prepared} <- prepare(signal, records) do
        transact(
          limits.admission_timeout_ms,
          fn -> admit_prepared(signal, prepared, limits) end,
          caller: {__MODULE__, :admit},
          telemetry_options: [signal: signal]
        )
      end

    RuntimeMetrics.admission(signal, result, started)

    case result do
      {:ok, %{skipped: skipped} = plan} ->
        log_skipped(signal, skipped, limits)

        cond do
          plan.batch_full? -> admit_slice(signal, records, limits)
          plan.overloaded -> {:error, {:overloaded, plan.overloaded}}
          true -> {:ok, plan.keys}
        end

      {:error, _} = error ->
        error
    end
  end

  # A partial plan commits its admitted prefix and returns the dimension that
  # stopped it as a value, never a rollback: the prefix is durable and replay
  # safe, and a caller's enclosing transaction stays usable.
  defp admit_prepared(signal, prepared, limits) do
    lock_admission()
    rules = active_rules(signal, limits.batch_work)
    require_ok(within(length(rules), limits.batch_work, :rule_inventory))
    plan = plan(rules, prepared, limits)
    insert(plan.admitted, plan.skipped, signal)
    enqueue_hints(plan.admitted)
    plan
  end

  @doc "Appends a stale-resolution ordering barrier behind all previously accepted rule input."
  def admit_maintenance(rule_name, cutoff, now, live_series_keys) do
    with :ok <- Rollout.admission_ready(),
         {:ok, {keys, _admitted}} <-
           admit_maintenance_ready(rule_name, cutoff, now, live_series_keys) do
      {:ok, keys}
    end
  end

  defp admit_maintenance_ready(rule_name, cutoff, now, live_series_keys) do
    limits = limits()
    source_key = "maintenance:" <> Ash.UUID.generate()
    payload = %{cutoff: cutoff, now: now, live_series_keys: MapSet.to_list(live_series_keys)}
    json = Jason.encode!(payload)
    payload = Jason.decode!(json)

    transact(
      limits.admission_timeout_ms,
      fn ->
        lock_admission()

        rules =
          StatefulAlertRule
          |> Ash.Query.for_read(:active, %{})
          |> Ash.Query.filter(name == ^rule_name)
          |> Ash.read!(actor: actor())
          |> Page.unwrap!()

        candidates =
          Enum.map(rules, fn rule ->
            revision = Input.revision(rule)

            %{
              rule_id: rule.id,
              source_key: source_key,
              rule_revision: revision,
              payload: payload,
              payload_bytes: byte_size(json) + byte_size(Jason.encode!(revision))
            }
          end)

        commit_candidates(candidates, :maintenance, limits)
      end,
      caller: {__MODULE__, :admit_maintenance}
    )
  rescue
    error -> {:error, {:invalid_payload, error}}
  end

  @doc false
  def lock_admission do
    # TRUNCATE takes its relation lock before its trigger runs. Match that
    # acquisition order to avoid a relation/advisory lock inversion.
    Repo.query!("LOCK TABLE platform.stateful_alert_rules IN ACCESS SHARE MODE")
    require_ok(AdvisoryLocks.acquire_ordered([{:exclusive, @admission_key}]))
  end

  defp commit_candidates(candidates, signal, limits) do
    require_ok(within(length(candidates), limits.batch_work, :batch_work))
    pending = reject_replays(candidates)
    require_capacity(pending, limits)
    insert(pending, [], signal)
    enqueue_hints(pending)
    {Enum.map(candidates, &{&1.rule_id, &1.source_key}), length(pending)}
  end

  defp enqueue_hints(admitted) do
    admitted
    |> Enum.map(& &1.rule_id)
    |> Enum.uniq()
    |> Enum.each(&enqueue_hint/1)
  end

  # Hints commit with the source transaction, but a failed hint insert must
  # not poison that transaction or discard the authoritative accepted work.
  defp enqueue_hint(rule_id) do
    Repo.query!("SAVEPOINT alert_evaluation_hint")

    result =
      try do
        insert_hint(rule_id)
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, _job} ->
        Repo.query!("RELEASE SAVEPOINT alert_evaluation_hint")

      {:error, _reason} ->
        Repo.query!("ROLLBACK TO SAVEPOINT alert_evaluation_hint")
        Repo.query!("RELEASE SAVEPOINT alert_evaluation_hint")
        RuntimeMetrics.store_failure()
        Logger.warning("Alert evaluation wake-up deferred to durable recovery")
    end

    :ok
  end

  # Admission is serialized by the short admission mutex. Coalesce wake-ups
  # here without Oban's unique-insert nested transaction: its exception path
  # marks the enclosing DBConnection transaction failed even after a SQL
  # savepoint rollback. Bulk insertion uses Oban's public API and stays inside
  # our savepoint. A racing recovery hint is harmless under the owner fence.
  defp insert_hint(rule_id) do
    worker = Oban.Worker.to_string(EvaluationWorker)

    case Repo.query!(
           "SELECT id FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = $2 " <>
             "AND state IN ('available', 'scheduled', 'retryable') LIMIT 1",
           [worker, rule_id]
         ) do
      %{rows: [[_id]]} ->
        {:ok, :already_scheduled}

      %{rows: []} ->
        case Oban.insert_all([EvaluationWorker.new(%{"rule_id" => rule_id})]) do
          [job] -> {:ok, job}
          other -> {:error, {:evaluation_hint_insert, other}}
        end
    end
  end

  @doc "Configured admission bounds; these apply to retries and direct callers alike."
  def limits do
    configured = Application.get_env(:serviceradar_core, :alert_evaluation_limits, [])

    Map.new(@defaults, fn {key, default} ->
      case Keyword.get(configured, key, default) do
        value when is_integer(value) and value > 0 -> {key, value}
        _ -> raise ArgumentError, "alert evaluation #{key} must be positive"
      end
    end)
  end

  def actor, do: SystemActor.system(:alert_engine)

  def evaluation_key(rule_id), do: "alert-evaluation:owner:v1:#{rule_id}"

  # PostgreSQL's lock and statement timeouts enforce `timeout` per statement: an
  # expired statement is cancelled, the transaction rolls back and the connection
  # stays usable. The client checkout deadline is per transaction and only
  # backstops a store PostgreSQL cannot reach, so size it for multiple round
  # trips with a floor for short tail polls in Completion.await/2. The
  # transaction owns the notification queue (`NotificationQueue.with_queue/1`).
  def transact(timeout, work, opts \\ []) do
    NotificationQueue.with_queue(fn -> run_transaction(timeout, work, opts) end)
  end

  defp run_transaction(timeout, work, opts) do
    caller = Keyword.get(opts, :caller, {__MODULE__, :transact})
    maybe_set_process_label(caller)

    telemetry_options =
      Keyword.merge(
        [caller: caller, timeout_ms: timeout],
        Keyword.get(opts, :telemetry_options, [])
      )

    Repo.transaction(
      fn ->
        %{rows: [[lock_timeout, statement_timeout]]} =
          Repo.query!(
            "SELECT current_setting('lock_timeout'), current_setting('statement_timeout')",
            [],
            telemetry_options: telemetry_options
          )

        set_timeouts("#{timeout}ms", "#{timeout}ms", telemetry_options)
        result = work.()
        # A nested caller transaction (including a sandbox) keeps SET LOCAL
        # values until its own end. Do not leave our short budget on it.
        set_timeouts(lock_timeout, statement_timeout, telemetry_options)
        result
      end,
      timeout: client_timeout(timeout),
      telemetry_options: telemetry_options
    )
  rescue
    error -> {:error, {:store_unavailable, error}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp client_timeout(timeout) do
    max(timeout * @client_backstop_multiplier, @min_client_timeout_ms)
  end

  defp set_timeouts(lock_timeout, statement_timeout, telemetry_options) do
    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $2, true)",
      [lock_timeout, statement_timeout],
      telemetry_options: telemetry_options
    )
  end

  defp maybe_set_process_label(caller) do
    case Process.info(self(), :registered_name) do
      {:registered_name, []} -> Process.set_label(caller)
      _ -> :ok
    end
  end

  defp prepare(signal, records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case Input.prepare(signal, record) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp active_rules(signal, limit) do
    StatefulAlertRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(signal == ^signal)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read!(actor: actor())
    |> Page.unwrap!()
  catch
    :throw, {DBConnection, connection, reason} ->
      # Ash may roll back with its query instead of raising. Preserve the
      # transaction rollback while exposing the admission failure contract.
      throw({DBConnection, connection, {:store_unavailable, reason}})
  end

  # Walks the eligible occurrences rule by rule, in input order, and admits
  # each rule's longest prefix that fits. A rule stops at its first occurrence
  # that does not fit, so its later occurrences never overtake it; the shared
  # pending budget stops every rule. Replays are found a bounded chunk at a time
  # and never consume capacity.
  defp plan(rules, records, limits) do
    records = Enum.map(records, &Map.put(&1, :record, Input.restore_record(&1.payload)))

    initial = %{
      admitted: [],
      admitted_count: 0,
      keys: [],
      skipped: [],
      blocked: MapSet.new(),
      overloaded: nil,
      full?: false,
      count: 0,
      bytes: 0,
      by_rule: nil
    }

    rules
    |> candidates(records)
    |> Stream.chunk_every(limits.batch_work)
    |> Enum.reduce_while(initial, fn chunk, acc ->
      {replayed, fresh} = split_replays(chunk)
      acc = %{acc | keys: Enum.reduce(replayed, acc.keys, &[key(&1) | &2])}
      acc = Enum.reduce(fresh, with_backlog(acc, rules, fresh), &place(&1, &2, limits))
      if acc.full?, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> then(fn acc ->
      %{
        admitted: Enum.reverse(acc.admitted),
        keys: Enum.reverse(acc.keys),
        skipped: Enum.reverse(acc.skipped),
        overloaded: acc.overloaded,
        batch_full?: acc.full? and acc.admitted_count >= limits.batch_work
      }
    end)
  end

  defp candidates(rules, records) do
    rules
    |> Stream.flat_map(fn rule ->
      revision = Input.revision(rule)
      revision_bytes = byte_size(Jason.encode!(revision))

      records
      |> Stream.filter(&eligible?(rule, &1.record))
      |> Stream.map(fn record ->
        %{
          rule_id: rule.id,
          source_key: record.source_key,
          rule_revision: revision,
          payload: record.payload,
          payload_bytes: record.bytes + revision_bytes
        }
      end)
    end)
    |> Stream.uniq_by(&key/1)
  end

  defp key(candidate), do: {candidate.rule_id, candidate.source_key}

  # Capacity is read once, and only when an occurrence needs admitting: most
  # batches match no rule and must not pay for the backlog aggregates.
  defp with_backlog(acc, _rules, []), do: acc

  defp with_backlog(%{by_rule: nil} = acc, rules, _fresh) do
    {count, bytes, by_rule} = backlog(Enum.map(rules, & &1.id))
    %{acc | count: count, bytes: bytes, by_rule: by_rule}
  end

  defp with_backlog(acc, _rules, _fresh), do: acc

  defp place(_candidate, %{full?: true} = acc, _limits), do: acc

  defp place(candidate, acc, limits) do
    cond do
      MapSet.member?(acc.blocked, candidate.rule_id) ->
        acc

      candidate.payload_bytes > min(limits.rule_bytes, limits.pending_bytes) ->
        %{acc | skipped: [candidate | acc.skipped], keys: [key(candidate) | acc.keys]}

      true ->
        case over_budget(candidate, acc, limits) do
          nil ->
            {rule_count, rule_bytes} = Map.get(acc.by_rule, candidate.rule_id, {0, 0})

            %{
              acc
              | admitted: [candidate | acc.admitted],
                admitted_count: acc.admitted_count + 1,
                keys: [key(candidate) | acc.keys],
                count: acc.count + 1,
                bytes: acc.bytes + candidate.payload_bytes,
                by_rule:
                  Map.put(
                    acc.by_rule,
                    candidate.rule_id,
                    {rule_count + 1, rule_bytes + candidate.payload_bytes}
                  )
            }

          {:rule, dimension} ->
            %{
              acc
              | blocked: MapSet.put(acc.blocked, candidate.rule_id),
                overloaded: acc.overloaded || dimension
            }

          {:shared, dimension} ->
            %{acc | full?: true, overloaded: acc.overloaded || dimension}
        end
    end
  end

  defp over_budget(candidate, acc, limits) do
    {rule_count, rule_bytes} = Map.get(acc.by_rule, candidate.rule_id, {0, 0})

    cond do
      acc.admitted_count >= limits.batch_work -> {:shared, :batch_work}
      acc.count + 1 > limits.pending_count -> {:shared, :pending_count}
      acc.bytes + candidate.payload_bytes > limits.pending_bytes -> {:shared, :pending_bytes}
      rule_count + 1 > limits.rule_count -> {:rule, :rule_count}
      rule_bytes + candidate.payload_bytes > limits.rule_bytes -> {:rule, :rule_bytes}
      true -> nil
    end
  end

  defp log_skipped(_signal, [], _limits), do: :ok

  defp log_skipped(signal, skipped, limits) do
    RuntimeMetrics.skipped(signal, length(skipped))
    largest = skipped |> Enum.map(& &1.payload_bytes) |> Enum.max()

    rule_ids = skipped |> Enum.map(& &1.rule_id) |> Enum.uniq() |> Enum.join(", ")

    Logger.warning(
      "Alert evaluation skipped #{length(skipped)} #{signal} occurrence(s) larger than the " <>
        "#{min(limits.rule_bytes, limits.pending_bytes)}-byte admission budget " <>
        "(largest #{largest} bytes) for rule(s) #{rule_ids}: the records are stored " <>
        "but these rules do not evaluate them"
    )
  end

  defp eligible?(%{signal: :log} = rule, record), do: RuleMatcher.rule_matches_log?(record, rule)

  defp eligible?(%{signal: :event} = rule, record) do
    # The owner runs the authoritative state machine; admission only bounds
    # which records can reach it.
    not Record.skip_engine_event?(record) and RuleMatcher.event_candidate?(record, rule)
  end

  defp eligible?(%{signal: :metric} = rule, record),
    do: RuleMatcher.rule_matches_metric?(record, rule)

  defp reject_replays(candidates) do
    {_replayed, fresh} = split_replays(candidates)
    fresh
  end

  defp split_replays([]), do: {[], []}

  defp split_replays(candidates) do
    rule_ids = candidates |> Enum.map(& &1.rule_id) |> Enum.uniq()
    source_keys = candidates |> Enum.map(& &1.source_key) |> Enum.uniq()

    recorded =
      [Work, Receipt]
      |> Enum.flat_map(fn resource ->
        resource
        |> Ash.Query.filter(rule_id in ^rule_ids and source_key in ^source_keys)
        |> Ash.Query.select([:rule_id, :source_key])
        |> Ash.read!(actor: actor())
      end)
      |> MapSet.new(&{&1.rule_id, &1.source_key})

    Enum.split_with(candidates, &MapSet.member?(recorded, key(&1)))
  end

  defp require_capacity([], _limits), do: :ok

  defp require_capacity(candidates, limits) do
    grouped = Enum.group_by(candidates, & &1.rule_id)
    {count, bytes, existing} = backlog(Map.keys(grouped))

    require_ok(within(count + length(candidates), limits.pending_count, :pending_count))

    require_ok(
      within(
        bytes + Enum.sum(Enum.map(candidates, & &1.payload_bytes)),
        limits.pending_bytes,
        :pending_bytes
      )
    )

    Enum.each(grouped, fn {rule_id, records} ->
      {count, bytes} = Map.get(existing, rule_id, {0, 0})
      require_ok(within(count + length(records), limits.rule_count, :rule_count))

      require_ok(
        within(
          bytes + Enum.sum(Enum.map(records, & &1.payload_bytes)),
          limits.rule_bytes,
          :rule_bytes
        )
      )
    end)
  end

  # Resources own the schema and writes. These aggregates are deliberately in
  # the short admission transaction; no evaluator holds its capacity lock.
  defp backlog(rule_ids) do
    %{rows: [[count, bytes]]} =
      Repo.query!(
        "SELECT count(*), coalesce(sum(payload_bytes), 0)::bigint FROM platform.alert_evaluation_work"
      )

    %{rows: rows} =
      Repo.query!(
        "SELECT rule_id, count(*), coalesce(sum(payload_bytes), 0)::bigint FROM platform.alert_evaluation_work WHERE rule_id = ANY($1::uuid[]) GROUP BY rule_id",
        [Enum.map(rule_ids, &Ecto.UUID.dump!/1)]
      )

    by_rule =
      Map.new(rows, fn [raw_id, count, bytes] -> {Ecto.UUID.load!(raw_id), {count, bytes}} end)

    {count, bytes, by_rule}
  end

  defp insert(admitted, skipped, signal) do
    now = DateTime.utc_now()

    entries = Enum.map(admitted, &{:work, &1}) ++ Enum.map(skipped, &{:skipped, &1})

    {work, receipts} =
      entries
      |> Enum.group_by(fn {_kind, candidate} -> candidate.rule_id end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {rule_id, records} ->
        {lane, registered} =
          Lane
          |> Ash.Changeset.for_create(:register, %{rule_id: rule_id}, actor: actor())
          |> Ash.create!(return_notifications?: true)

        {_lane, reserved} =
          lane
          |> Ash.Changeset.for_update(
            :reserve,
            %{next_position: lane.next_position + length(records)},
            actor: actor()
          )
          |> Ash.update!(return_notifications?: true)

        NotificationQueue.notify_after_commit(registered ++ reserved)

        Enum.with_index(records, lane.next_position + 1)
      end)
      |> Enum.split_with(fn {{kind, _candidate}, _position} -> kind == :work end)

    work
    |> Enum.map(fn {{:work, record}, position} ->
      Map.merge(record, %{position: position, signal: signal, available_at: now})
    end)
    |> bulk_create(Work, :admit)

    receipts
    |> Enum.map(fn {{:skipped, candidate}, position} ->
      %{
        rule_id: candidate.rule_id,
        source_key: candidate.source_key,
        position: position,
        disposition: :cancelled,
        details: %{reason: "record_too_large", payload_bytes: candidate.payload_bytes}
      }
    end)
    |> bulk_create(Receipt, :record)
  end

  defp bulk_create([], _resource, _action), do: :ok

  defp bulk_create(params, resource, action) do
    case Ash.bulk_create(params, resource, action,
           actor: actor(),
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> Repo.rollback({:admission_failed, errors})
    end
  end

  defp within(value, limit, _dimension) when value <= limit, do: :ok
  defp within(_value, _limit, dimension), do: {:error, {:overloaded, dimension}}
  defp require_ok(:ok), do: :ok
  defp require_ok({:error, reason}), do: Repo.rollback(reason)
end
