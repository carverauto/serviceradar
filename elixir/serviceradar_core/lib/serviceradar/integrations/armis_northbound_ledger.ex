defmodule ServiceRadar.Integrations.ArmisNorthboundLedger do
  @moduledoc """
  Persists the collection-bound, one-row-per-Armis-ID northbound ledger.

  The collection and every initial disposition are committed before the first
  outbound request. Eligible rows move from `pending` to one terminal outcome;
  withheld rows never become outbound targets.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Integrations.ArmisNorthboundRetention
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Integrations.IntegrationUpdateRunTarget
  alias ServiceRadar.Repo

  require Logger

  @terminal_outcomes [:accepted, :failed, :unattempted]

  @spec examples(Ecto.UUID.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def examples(run_id, opts \\ []) do
    per_group = opts |> Keyword.get(:per_group, 5) |> max(1) |> min(20)

    sql = """
    SELECT source_object_id, canonical_device_uid, eligibility, outcome, reason
    FROM (
      SELECT source_object_id,
             canonical_device_uid,
             eligibility,
             outcome,
             reason,
             row_number() OVER (
               PARTITION BY outcome, COALESCE(reason, '')
               ORDER BY source_object_id
             ) AS group_row
      FROM platform.integration_update_run_targets
      WHERE integration_update_run_id = $1::uuid
        AND outcome <> 'accepted'
    ) grouped
    WHERE group_row <= $2
    ORDER BY outcome, reason NULLS FIRST, source_object_id
    """

    case SQL.query(Repo, sql, [to_string(run_id), per_group]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [source_id, device_uid, eligibility, outcome, reason] ->
           %{
             source_object_id: source_id,
             canonical_device_uid: device_uid,
             eligibility: eligibility,
             outcome: outcome,
             reason: reason
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec bind(IntegrationUpdateRun.t() | map(), map(), term()) ::
          {:ok, IntegrationUpdateRun.t() | map()} | {:error, term()}
  def bind(run, %{accounted?: true} = population, actor) do
    with :ok <- validate_population(population) do
      transaction(fn ->
        with {:ok, bound_run} <- bind_collection(run, population, actor),
             :ok <- insert_targets(bound_run, population),
             :ok <- verify_target_count(bound_run.id, population.distinct_source_ids) do
          bound_run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def bind(run, _population, _actor), do: {:ok, run}

  @spec finalize(IntegrationUpdateRun.t() | map(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def finalize(run, %{accounted?: true} = population, result) do
    with {:ok, outcomes} <- normalize_outcomes(population, result) do
      case transaction(fn ->
             Enum.each(@terminal_outcomes, fn outcome ->
               source_ids = Map.fetch!(outcomes, outcome)
               update_outcome(run.id, source_ids, outcome)
             end)

             with {:ok, counts} <- persisted_counts(run.id),
                  :ok <- validate_final_counts(population, counts) do
               result
               |> Map.merge(counts)
               |> Map.put(:updated_count, counts.accepted_count)
               |> Map.put(:skipped_count, counts.withheld_count)
               |> Map.put(:reconciliation_status, reconciliation_status(counts))
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, _result} = ok ->
          prune_accepted_detail()
          ok

        {:error, _reason} = error ->
          error
      end
    end
  end

  def finalize(_run, _population, result), do: {:ok, result}

  @doc """
  Finalizes every still-pending eligible target as unattempted.

  This is the crash/reaper path for a collection-bound run. Outcomes already
  recorded as accepted or failed are preserved, and the returned counts are
  read back from the ledger before the parent run may leave `running`.
  """
  @spec abort_pending(IntegrationUpdateRun.t() | map()) :: {:ok, map()} | {:error, term()}
  def abort_pending(%{collection_id: collection_id} = run)
      when is_binary(collection_id) and collection_id != "" do
    transaction(fn ->
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      IntegrationUpdateRunTarget
      |> where(
        [target],
        target.integration_update_run_id == ^run.id and target.eligibility == :eligible and
          target.outcome == :pending
      )
      |> Repo.update_all(set: [outcome: :unattempted, updated_at: now])

      with {:ok, counts} <- persisted_counts(run.id),
           :ok <- validate_bound_run_counts(run, counts) do
        Map.merge(counts, %{
          device_count: Map.get(run, :distinct_source_ids, 0),
          eligible_count: Map.get(run, :eligible_count, 0),
          updated_count: counts.accepted_count,
          skipped_count: counts.withheld_count,
          error_count: counts.failed_count + counts.unattempted_count,
          reconciliation_status: :failed
        })
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def abort_pending(_run), do: {:error, :run_not_collection_bound}

  @doc false
  def validate_population(population) do
    accounting = Map.get(population, :accounting, %{})
    raw = Map.get(accounting, :raw_rows)
    excluded = Map.get(accounting, :excluded_rows)
    invalid = Map.get(accounting, :invalid_rows)
    valid = Map.get(accounting, :valid_occurrences)
    distinct = Map.get(accounting, :distinct_source_ids)
    duplicates = Map.get(accounting, :duplicate_occurrences)
    eligible = Map.get(population, :eligible_count)
    withheld = Map.get(population, :withheld_count)

    cond do
      not Enum.all?(
        [raw, excluded, invalid, valid, distinct, duplicates, eligible, withheld],
        &(is_integer(&1) and &1 >= 0)
      ) ->
        {:error, :invalid_population_counts}

      raw != excluded + invalid + valid ->
        {:error, :raw_population_equation_mismatch}

      valid != distinct + duplicates ->
        {:error, :valid_population_equation_mismatch}

      distinct != eligible + withheld ->
        {:error, :disposition_population_equation_mismatch}

      true ->
        :ok
    end
  end

  @doc false
  def reconciliation_status(%{withheld_count: 0, failed_count: 0, unattempted_count: 0}),
    do: :reconciled

  def reconciliation_status(_counts), do: :degraded

  defp bind_collection(run, population, actor) do
    accounting = population.accounting
    snapshot = population.snapshot

    attrs = %{
      collection_id: accounting.collection_id,
      collection_content_hash: accounting.collection_content_hash,
      collection_observed_at: accounting.collection_observed_at,
      raw_rows: accounting.raw_rows,
      excluded_rows: accounting.excluded_rows,
      invalid_rows: accounting.invalid_rows,
      valid_occurrences: accounting.valid_occurrences,
      distinct_source_ids: accounting.distinct_source_ids,
      duplicate_occurrences: accounting.duplicate_occurrences,
      conflicting_duplicate_ids: accounting.conflicting_duplicate_ids,
      eligible_count: population.eligible_count,
      withheld_count: population.withheld_count,
      reconciliation_status: :pending,
      metadata: %{
        "collection_activated_at" => snapshot.activated_at,
        "withheld_reason_counts" => population.reason_counts,
        "accounting_status" => "exact"
      }
    }

    Ash.update(run, attrs,
      action: :bind_collection,
      actor: actor,
      domain: ServiceRadar.Integrations
    )
  end

  defp insert_targets(run, population) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    rows =
      Enum.map(population.eligible ++ population.withheld, fn disposition ->
        %{
          integration_update_run_id: run.id,
          collection_id: population.accounting.collection_id,
          source_object_id: disposition.source_object_id,
          canonical_device_uid: disposition.canonical_device_uid,
          eligibility: disposition.disposition,
          outcome: initial_outcome(disposition.disposition),
          reason: disposition.reason,
          is_available: disposition.is_available,
          metadata: disposition.metadata || %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      :ok
    else
      {_count, _returning} =
        Repo.insert_all(IntegrationUpdateRunTarget, rows,
          on_conflict: :nothing,
          conflict_target: [:integration_update_run_id, :source_object_id]
        )

      :ok
    end
  end

  defp initial_outcome(:eligible), do: :pending
  defp initial_outcome(:withheld), do: :withheld

  defp verify_target_count(run_id, expected) do
    actual =
      IntegrationUpdateRunTarget
      |> where([target], target.integration_update_run_id == ^run_id)
      |> Repo.aggregate(:count)

    if actual == expected,
      do: :ok,
      else: {:error, {:run_target_count_mismatch, expected, actual}}
  end

  defp normalize_outcomes(population, result) do
    eligible = MapSet.new(population.eligible, & &1.source_object_id)
    accepted = source_id_set(result, :accepted_ids)
    failed = source_id_set(result, :failed_ids)
    unattempted = source_id_set(result, :unattempted_ids)
    union = accepted |> MapSet.union(failed) |> MapSet.union(unattempted)

    cond do
      not disjoint?([accepted, failed, unattempted]) ->
        {:error, :outbound_outcome_overlap}

      union != eligible ->
        {:error,
         {:outbound_outcome_membership_mismatch,
          %{expected: MapSet.size(eligible), actual: MapSet.size(union)}}}

      true ->
        {:ok,
         %{
           accepted: MapSet.to_list(accepted),
           failed: MapSet.to_list(failed),
           unattempted: MapSet.to_list(unattempted)
         }}
    end
  end

  defp source_id_set(result, key) do
    result
    |> Map.get(key, [])
    |> MapSet.new(&to_string/1)
  end

  defp disjoint?([first, second, third]) do
    MapSet.disjoint?(first, second) and MapSet.disjoint?(first, third) and
      MapSet.disjoint?(second, third)
  end

  defp update_outcome(_run_id, [], _outcome), do: :ok

  defp update_outcome(run_id, source_ids, outcome) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {count, _} =
      IntegrationUpdateRunTarget
      |> where(
        [target],
        target.integration_update_run_id == ^run_id and
          target.source_object_id in ^source_ids and target.eligibility == :eligible and
          target.outcome == :pending
      )
      |> Repo.update_all(set: [outcome: outcome, updated_at: now])

    if count == length(source_ids),
      do: :ok,
      else:
        Repo.rollback({:run_target_outcome_count_mismatch, outcome, length(source_ids), count})
  end

  defp persisted_counts(run_id) do
    rows =
      IntegrationUpdateRunTarget
      |> where([target], target.integration_update_run_id == ^run_id)
      |> group_by([target], [target.eligibility, target.outcome])
      |> select([target], {target.eligibility, target.outcome, count(target.id)})
      |> Repo.all()

    counts =
      Enum.reduce(rows, empty_counts(), fn
        {:withheld, :withheld, count}, acc -> %{acc | withheld_count: count}
        {:eligible, :accepted, count}, acc -> %{acc | accepted_count: count}
        {:eligible, :failed, count}, acc -> %{acc | failed_count: count}
        {:eligible, :unattempted, count}, acc -> %{acc | unattempted_count: count}
        {_eligibility, :pending, _count}, acc -> Map.put(acc, :pending?, true)
        _row, acc -> Map.put(acc, :invalid?, true)
      end)

    if counts.pending? or counts.invalid? do
      {:error, :nonterminal_run_target_outcome}
    else
      {:ok, Map.drop(counts, [:pending?, :invalid?])}
    end
  end

  defp empty_counts do
    %{
      withheld_count: 0,
      accepted_count: 0,
      failed_count: 0,
      unattempted_count: 0,
      pending?: false,
      invalid?: false
    }
  end

  defp validate_final_counts(population, counts) do
    eligible = counts.accepted_count + counts.failed_count + counts.unattempted_count

    cond do
      counts.withheld_count != population.withheld_count ->
        {:error, :persisted_withheld_count_mismatch}

      eligible != population.eligible_count ->
        {:error, :persisted_eligible_count_mismatch}

      population.distinct_source_ids != eligible + counts.withheld_count ->
        {:error, :persisted_population_equation_mismatch}

      true ->
        :ok
    end
  end

  defp validate_bound_run_counts(run, counts) do
    eligible = counts.accepted_count + counts.failed_count + counts.unattempted_count

    cond do
      counts.withheld_count != Map.get(run, :withheld_count, 0) ->
        {:error, :persisted_withheld_count_mismatch}

      eligible != Map.get(run, :eligible_count, 0) ->
        {:error, :persisted_eligible_count_mismatch}

      Map.get(run, :distinct_source_ids, 0) != eligible + counts.withheld_count ->
        {:error, :persisted_population_equation_mismatch}

      true ->
        :ok
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prune_accepted_detail do
    case ArmisNorthboundRetention.prune() do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Armis northbound target retention failed: #{inspect(reason)}")
    end
  end
end
