defmodule ServiceRadar.Automation.Ansible.AwxInventoryObservationFence do
  @moduledoc """
  Orders AWX controller observations independently of membership authority.

  One plugin aggregate covers every inventory visible to a controller. Both
  partial and complete-empty aggregates advance this watermark. The locked
  check and advance belong to the membership transaction, so a failed write
  cannot acknowledge an observation that did not finish reconciling.
  """

  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Repo

  @table "platform.ansible_awx_inventory_observations"

  def with_locks(aggregates, fun) do
    Repo.transaction(
      fn ->
        aggregates
        |> Enum.sort_by(& &1.controller_id)
        |> Enum.each(fn aggregate ->
          case lock_and_check(aggregate) do
            {:ok, _disposition} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: :infinity
    )
  end

  def check(aggregate) do
    case read(aggregate.controller_id) do
      {:ok, current} -> disposition(aggregate, current)
      {:error, _} = error -> error
    end
  end

  def lock_and_check(aggregate) do
    with {:ok, _} <-
           Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
             "awx-inventory-observation:" <> aggregate.controller_id
           ]) do
      check(aggregate)
    end
  end

  @doc false
  def disposition(_aggregate, nil), do: {:ok, :initial}

  def disposition(aggregate, current) do
    cond do
      aggregate.source_generation < current.source_generation ->
        {:error,
         {:stale_awx_membership_generation, aggregate.controller_id, aggregate.source_generation,
          current.source_generation}}

      aggregate.source_generation == current.source_generation ->
        if digest(aggregate) == current.observation_digest,
          do: {:ok, :replay},
          else:
            {:error,
             {:conflicting_awx_inventory_observation, aggregate.controller_id,
              aggregate.source_generation}}

      true ->
        {:ok, :advance}
    end
  end

  def advance(aggregate) do
    statement = """
    INSERT INTO #{@table} AS current
      (controller_id, source_generation, source_fingerprint, observation_digest,
       observed_at, complete, inserted_at, updated_at)
    VALUES (($1::text)::uuid, $2, $3, $4, $5, $6, now(), now())
    ON CONFLICT (controller_id) DO UPDATE SET
      source_generation = EXCLUDED.source_generation,
      source_fingerprint = EXCLUDED.source_fingerprint,
      observation_digest = EXCLUDED.observation_digest,
      observed_at = EXCLUDED.observed_at,
      complete = EXCLUDED.complete,
      updated_at = now()
    WHERE current.source_generation < EXCLUDED.source_generation
       OR (current.source_generation = EXCLUDED.source_generation
           AND current.observation_digest = EXCLUDED.observation_digest)
    """

    case Repo.query(statement, [
           aggregate.controller_id,
           aggregate.source_generation,
           aggregate.source_fingerprint,
           digest(aggregate),
           DateTime.to_naive(aggregate.observed_at),
           aggregate.complete
         ]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :awx_inventory_observation_conflict}
      {:error, _} = error -> error
    end
  end

  @doc false
  def digest(aggregate) do
    aggregate
    |> Map.take([:controller_id, :source_generation, :source_fingerprint, :complete, :hosts])
    |> Map.update!(
      :hosts,
      &Enum.sort_by(&1, fn host -> {host.inventory_id, host.awx_host_id} end)
    )
    |> Map.put(:observed_at, DateTime.to_iso8601(aggregate.observed_at))
    |> Map.put(:collection_id, aggregate.collection_id)
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp read(controller_id) do
    case Repo.query(
           "SELECT source_generation, observation_digest FROM #{@table} WHERE controller_id = ($1::text)::uuid",
           [controller_id]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[generation, digest]]}} ->
        {:ok, %{source_generation: generation, observation_digest: digest}}

      {:error, _} = error ->
        error
    end
  end
end
