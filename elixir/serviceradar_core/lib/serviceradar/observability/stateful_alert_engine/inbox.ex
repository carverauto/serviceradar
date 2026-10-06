defmodule ServiceRadar.Observability.StatefulAlertEngine.Inbox do
  @moduledoc """
  Bounded, all-or-nothing durable admission for stateful alert evaluation.

  The admission mutex only covers capacity, replay lookup and committed input
  order. Evaluators use a different fence and never acquire this mutex, so a
  slow rule cannot delay admission for another rule. Accepted rows have no TTL.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.AlertEvaluationLane, as: Lane
  alias ServiceRadar.Observability.AlertEvaluationReceipt, as: Receipt
  alias ServiceRadar.Observability.AlertEvaluationWork, as: Work
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.Input
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Repo

  require Ash.Query

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

  @doc "Commits every eligible rule occurrence or rejects the entire batch."
  def admit(signal, records) when signal in [:log, :event, :metric] and is_list(records) do
    limits = limits()

    with :ok <- within(length(records), limits.batch_records, :batch_records),
         {:ok, prepared} <- prepare(signal, records) do
      transact(limits.admission_timeout_ms, fn ->
        # TRUNCATE takes its relation lock before its trigger runs. Take this
        # compatible read lock before the advisory mutex, so replay cannot
        # hold the relation while waiting on a mutex we hold during a read.
        Repo.query!("LOCK TABLE platform.stateful_alert_rules IN ACCESS SHARE MODE")
        require_ok(AdvisoryLocks.acquire_ordered([{:exclusive, @admission_key}]))
        rules = active_rules(signal, limits.batch_work)
        require_ok(within(length(rules) * length(prepared), limits.batch_work, :batch_work))
        candidates = candidates(rules, prepared)
        pending = reject_replays(candidates)
        require_capacity(pending, limits)
        insert(pending, signal)

        pending
        |> Enum.map(& &1.rule_id)
        |> Enum.uniq()
        |> Enum.each(fn rule_id ->
          case EvaluationWorker.enqueue(rule_id) do
            {:ok, _job} -> :ok
            {:error, reason} -> Repo.rollback({:evaluation_enqueue_failed, reason})
          end
        end)

        Enum.map(candidates, &{&1.rule_id, &1.source_key})
      end)
    end
  end

  def admit(_signal, _records), do: {:error, :invalid_payload}

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

  # Transaction timeout bounds checkout and DB round trips. PostgreSQL's lock
  # and statement timeouts bound contention at the store itself as well.
  def transact(timeout, work) do
    Repo.transaction(
      fn ->
        Repo.query!(
          "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
          [
            "#{timeout}ms"
          ]
        )

        work.()
      end,
      timeout: timeout
    )
  rescue
    error -> {:error, {:store_unavailable, error}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
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
    |> ServiceRadar.Ash.Page.unwrap!()
  end

  defp candidates(rules, records) do
    rules
    |> Enum.flat_map(fn rule ->
      revision = Input.revision(rule)
      revision_bytes = byte_size(Jason.encode!(revision))

      Enum.map(records, fn record ->
        %{
          rule_id: rule.id,
          source_key: record.source_key,
          rule_revision: revision,
          payload: record.payload,
          payload_bytes: record.bytes + revision_bytes
        }
      end)
    end)
    |> Enum.uniq_by(&{&1.rule_id, &1.source_key})
  end

  defp reject_replays([]), do: []

  defp reject_replays(candidates) do
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

    Enum.reject(candidates, &MapSet.member?(recorded, {&1.rule_id, &1.source_key}))
  end

  defp require_capacity([], _limits), do: :ok

  defp require_capacity(candidates, limits) do
    # Resources own the schema and writes. This single aggregate is deliberately
    # in the short admission transaction; no evaluator holds its capacity lock.
    %{rows: [[count, bytes]]} =
      Repo.query!(
        "SELECT count(*), coalesce(sum(payload_bytes), 0)::bigint FROM platform.alert_evaluation_work"
      )

    require_ok(within(count + length(candidates), limits.pending_count, :pending_count))

    require_ok(
      within(
        bytes + Enum.sum(Enum.map(candidates, & &1.payload_bytes)),
        limits.pending_bytes,
        :pending_bytes
      )
    )

    grouped = Enum.group_by(candidates, & &1.rule_id)
    rule_ids = grouped |> Map.keys() |> Enum.map(&Ecto.UUID.dump!/1)

    %{rows: rows} =
      Repo.query!(
        "SELECT rule_id, count(*), coalesce(sum(payload_bytes), 0)::bigint FROM platform.alert_evaluation_work WHERE rule_id = ANY($1::uuid[]) GROUP BY rule_id",
        [rule_ids]
      )

    existing =
      Map.new(rows, fn [raw_id, count, bytes] -> {Ecto.UUID.load!(raw_id), {count, bytes}} end)

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

  defp insert(candidates, signal) do
    now = DateTime.utc_now()

    params =
      candidates
      |> Enum.group_by(& &1.rule_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {rule_id, records} ->
        lane =
          Lane
          |> Ash.Changeset.for_create(:register, %{rule_id: rule_id}, actor: actor())
          |> Ash.create!()

        lane
        |> Ash.Changeset.for_update(
          :reserve,
          %{next_position: lane.next_position + length(records)},
          actor: actor()
        )
        |> Ash.update!()

        records
        |> Enum.with_index(lane.next_position + 1)
        |> Enum.map(fn {record, position} ->
          Map.merge(record, %{position: position, signal: signal, available_at: now})
        end)
      end)

    case Ash.bulk_create(params, Work, :admit,
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
