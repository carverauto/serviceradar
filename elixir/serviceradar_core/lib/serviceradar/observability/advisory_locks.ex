defmodule ServiceRadar.Observability.AdvisoryLocks do
  @moduledoc """
  Batches transaction-scoped advisory locks without changing their identities.

  Callers own the transaction and the acquisition order. Blocking acquisition
  uses a recursive query with one lock per iteration so later locks cannot be
  evaluated ahead of an earlier lock. A failed try leaves successful locks held
  until the caller rolls back, just like PostgreSQL's individual try-lock calls.
  """

  alias ServiceRadar.Repo

  @type lock :: {:shared | :exclusive, String.t()}

  @ordered_sql """
  WITH RECURSIVE inputs AS (
    SELECT $1::text[] AS keys, $2::boolean[] AS shared
  ), acquired(ordinal, lock_result) AS (
    SELECT 1,
           CASE WHEN shared[1]
             THEN pg_advisory_xact_lock_shared(hashtextextended(keys[1], 0))
             ELSE pg_advisory_xact_lock(hashtextextended(keys[1], 0))
           END
    FROM inputs
    WHERE cardinality(keys) > 0
    UNION ALL
    SELECT acquired.ordinal + 1,
           CASE WHEN inputs.shared[acquired.ordinal + 1]
             THEN pg_advisory_xact_lock_shared(
               hashtextextended(inputs.keys[acquired.ordinal + 1], 0))
             ELSE pg_advisory_xact_lock(
               hashtextextended(inputs.keys[acquired.ordinal + 1], 0))
           END
    FROM acquired CROSS JOIN inputs
    WHERE acquired.ordinal < cardinality(inputs.keys)
  )
  SELECT count(*) FROM acquired
  """

  @try_sql """
  SELECT key, pg_try_advisory_xact_lock(hashtextextended(key, 0))
  FROM unnest($1::text[]) WITH ORDINALITY AS requested(key, ordinal)
  ORDER BY ordinal
  """

  @spec acquire_ordered([lock()]) :: :ok | {:error, term()}
  def acquire_ordered([]), do: :ok

  def acquire_ordered(locks) do
    case Repo.query(@ordered_sql, parameters(locks)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec acquire_ordered!([lock()]) :: :ok
  def acquire_ordered!([]), do: :ok

  def acquire_ordered!(locks) do
    Repo.query!(@ordered_sql, parameters(locks))
    :ok
  end

  @spec try_acquire_ordered([String.t()]) :: :ok | {:error, term()}
  def try_acquire_ordered([]), do: :ok

  def try_acquire_ordered(keys) do
    case Repo.query(@try_sql, [keys]) do
      {:ok, %{rows: rows}} ->
        busy = for [key, false] <- rows, do: key

        case busy do
          [] -> :ok
          busy -> {:error, {:advisory_locks_busy, busy}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parameters(locks) do
    {keys, shared} =
      Enum.unzip(
        Enum.map(locks, fn
          {:shared, key} when is_binary(key) -> {key, true}
          {:exclusive, key} when is_binary(key) -> {key, false}
        end)
      )

    [keys, shared]
  end
end
