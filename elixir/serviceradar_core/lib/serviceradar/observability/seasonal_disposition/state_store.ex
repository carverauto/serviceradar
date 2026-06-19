defmodule ServiceRadar.Observability.SeasonalDisposition.StateStore do
  @moduledoc """
  Persistent confirmation state for central seasonal disposition.

  State is keyed by the canonical `(source, series_key, dow, hod)` bucket so
  `confirm_slots > 1` survives Oban retries, worker restarts, and node moves.
  """

  alias ServiceRadar.Repo

  @default_ttl_seconds 180 * 24 * 60 * 60

  @type state_key :: {String.t(), integer(), integer()}

  @spec load(String.t(), state_key(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load(source, {series_key, dow, hod}, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    sql = """
    SELECT consecutive_anomalous
    FROM #{schema()}.seasonal_disposition_states
    WHERE source = $1
      AND series_key = $2
      AND dow = $3
      AND hod = $4
      AND (expires_at IS NULL OR expires_at > now())
    LIMIT 1
    """

    case repo.query(sql, [source, series_key, dow, hod]) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, %{rows: []}} -> {:ok, 0}
      {:ok, _other} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec persist(String.t(), state_key(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def persist(source, {series_key, dow, hod}, next, opts \\ [])
      when is_integer(next) and next >= 0 do
    repo = Keyword.get(opts, :repo, Repo)
    evaluated_at = Keyword.get(opts, :evaluated_at, DateTime.utc_now())
    expires_at = DateTime.add(evaluated_at, ttl_seconds(opts), :second)

    sql = """
    INSERT INTO #{schema()}.seasonal_disposition_states (
      source,
      series_key,
      dow,
      hod,
      consecutive_anomalous,
      last_seen_at,
      expires_at,
      updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, now())
    ON CONFLICT (source, series_key, dow, hod)
    DO UPDATE SET
      consecutive_anomalous = EXCLUDED.consecutive_anomalous,
      last_seen_at = EXCLUDED.last_seen_at,
      expires_at = EXCLUDED.expires_at,
      updated_at = now()
    """

    case repo.query(sql, [source, series_key, dow, hod, next, evaluated_at, expires_at]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    sql = """
    DELETE FROM #{schema()}.seasonal_disposition_states
    WHERE expires_at IS NOT NULL AND expires_at <= now()
    """

    case repo.query(sql, []) do
      {:ok, %{num_rows: count}} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, _result} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ttl_seconds(opts) do
    case Keyword.get(opts, :state_ttl_seconds, @default_ttl_seconds) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_ttl_seconds
    end
  end

  defp schema, do: "platform"
end
