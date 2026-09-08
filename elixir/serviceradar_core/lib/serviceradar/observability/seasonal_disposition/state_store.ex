defmodule ServiceRadar.Observability.SeasonalDisposition.StateStore do
  @moduledoc """
  Postgres-backed confirmation state for central seasonal disposition.

  State is keyed by the source and hour-of-week bucket so `confirm_slots > 1`
  survives Oban run boundaries, node restarts, and deploys. The worker loads and
  persists state in batches to avoid one query per profile row.
  """

  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Repo

  require Logger

  @table "seasonal_disposition_states"
  @prefix "platform"
  @default_ttl_days 190

  @type state_key :: {String.t(), integer(), integer()}
  @type action :: %{
          required(:key) => state_key(),
          required(:consecutive_anomalous) => non_neg_integer(),
          optional(:disposition) => String.t() | nil,
          optional(:status) => String.t() | nil,
          optional(:score) => number() | nil,
          optional(:evaluated_at) => DateTime.t() | nil,
          optional(:bucket_started_at) => DateTime.t() | nil,
          optional(:bucket_ended_at) => DateTime.t() | nil
        }

  @spec load_many(Source.t(), [state_key()], keyword()) :: {:ok, map()} | {:error, term()}
  def load_many(%Source{name: source_name}, keys, opts \\ []) when is_list(keys) do
    keys = Enum.uniq(keys)

    if keys == [] do
      {:ok, %{}}
    else
      repo = Keyword.get(opts, :repo, Repo)
      {series_keys, dows, hods} = split_keys(keys)

      sql = """
      SELECT series_key, dow, hod, consecutive_anomalous
      FROM #{@prefix}.#{@table}
      WHERE source = $1
        AND expires_at > now()
        AND (series_key, dow, hod) IN (
          SELECT *
          FROM unnest($2::text[], $3::int[], $4::int[])
        )
      """

      case repo.query(sql, [source_name, series_keys, dows, hods]) do
        {:ok, %{rows: rows}} ->
          {:ok, Map.new(rows, &row_to_state/1)}

        {:error, reason} = error ->
          Logger.warning("Failed to load seasonal disposition state",
            source: source_name,
            reason: inspect(reason)
          )

          error
      end
    end
  end

  @spec persist_many(Source.t(), [action()], keyword()) :: :ok | {:error, term()}
  def persist_many(%Source{name: source_name}, actions, opts \\ []) when is_list(actions) do
    actions = Enum.reject(actions, &is_nil/1)

    if actions == [] do
      :ok
    else
      repo = Keyword.get(opts, :repo, Repo)
      now = Keyword.get_lazy(opts, :now, &now/0)
      ttl_days = positive_integer(Keyword.get(opts, :seasonal_state_ttl_days), @default_ttl_days)
      expires_at = DateTime.add(now, ttl_days * 86_400, :second)

      rows =
        Enum.map(actions, fn action ->
          {series_key, dow, hod} = Map.fetch!(action, :key)

          %{
            source: source_name,
            series_key: series_key,
            dow: dow,
            hod: hod,
            consecutive_anomalous:
              non_negative_integer(Map.fetch!(action, :consecutive_anomalous)),
            last_disposition: string_value(Map.get(action, :disposition)),
            last_status: string_value(Map.get(action, :status)),
            last_score: number_value(Map.get(action, :score)),
            last_evaluated_at: Map.get(action, :evaluated_at),
            last_bucket_started_at: Map.get(action, :bucket_started_at),
            last_bucket_ended_at: Map.get(action, :bucket_ended_at),
            expires_at: expires_at,
            inserted_at: now,
            updated_at: now
          }
        end)

      case repo.insert_all(@table, rows,
             prefix: @prefix,
             conflict_target: [:source, :series_key, :dow, :hod],
             on_conflict: {:replace, replacement_fields()}
           ) do
        {count, _rows} when is_integer(count) ->
          :ok

        {:error, reason} = error ->
          Logger.warning("Failed to persist seasonal disposition state",
            source: source_name,
            reason: inspect(reason)
          )

          error

        other ->
          {:error, {:seasonal_state_persist_failed, other}}
      end
    end
  end

  @spec cleanup_expired(module()) :: :ok | {:error, term()}
  def cleanup_expired(repo \\ Repo) do
    case repo.query("DELETE FROM #{@prefix}.#{@table} WHERE expires_at <= now()", []) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Looks up the most recent central-seasonal disposition that overlaps an edge event.

  The alert layer uses this as the edge-vs-seasonal join: a confirmed edge spike
  can be suppressed only when the seasonal worker has already evaluated the same
  canonical series and bucket window as normal/suppressed. The join is window
  based instead of recomputing `(dow, hod)` so it respects the worker's configured
  profile timezone.
  """
  @spec lookup_window_disposition(String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def lookup_window_disposition(source_name, series_key, event_time, opts \\ [])

  def lookup_window_disposition(source_name, series_key, %DateTime{} = event_time, opts)
      when is_binary(source_name) and is_binary(series_key) do
    repo = Keyword.get(opts, :repo, Repo)

    sql = """
    SELECT source,
           series_key,
           dow,
           hod,
           last_disposition,
           last_status,
           last_score,
           last_evaluated_at,
           last_bucket_started_at,
           last_bucket_ended_at
    FROM #{@prefix}.#{@table}
    WHERE source = $1
      AND series_key = $2
      AND expires_at > now()
      AND last_bucket_started_at IS NOT NULL
      AND last_bucket_ended_at IS NOT NULL
      AND last_bucket_started_at <= $3
      AND last_bucket_ended_at > $3
    ORDER BY last_evaluated_at DESC NULLS LAST, updated_at DESC
    LIMIT 1
    """

    case repo.query(sql, [source_name, series_key, event_time]) do
      {:ok, %{rows: [row | _]}} ->
        {:ok, disposition_row(row)}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, reason} = error ->
        Logger.warning("Failed to lookup seasonal disposition state",
          source: source_name,
          series_key: series_key,
          reason: inspect(reason)
        )

        error
    end
  end

  def lookup_window_disposition(_source_name, _series_key, _event_time, _opts), do: {:ok, nil}

  defp split_keys(keys) do
    keys
    |> Enum.reduce({[], [], []}, fn {series_key, dow, hod}, {series_keys, dows, hods} ->
      {[series_key | series_keys], [dow | dows], [hod | hods]}
    end)
    |> then(fn {series_keys, dows, hods} ->
      {Enum.reverse(series_keys), Enum.reverse(dows), Enum.reverse(hods)}
    end)
  end

  defp row_to_state([series_key, dow, hod, consecutive_anomalous]) do
    {{series_key, dow, hod}, non_negative_integer(consecutive_anomalous)}
  end

  defp disposition_row([
         source,
         series_key,
         dow,
         hod,
         disposition,
         status,
         score,
         evaluated_at,
         bucket_started_at,
         bucket_ended_at
       ]) do
    %{
      source: source,
      series_key: series_key,
      dow: dow,
      hod: hod,
      disposition: disposition,
      status: status,
      score: score,
      evaluated_at: evaluated_at,
      bucket_started_at: bucket_started_at,
      bucket_ended_at: bucket_ended_at
    }
  end

  defp replacement_fields do
    [
      :consecutive_anomalous,
      :last_disposition,
      :last_status,
      :last_score,
      :last_evaluated_at,
      :last_bucket_started_at,
      :last_bucket_ended_at,
      :expires_at,
      :updated_at
    ]
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :microsecond)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(value) when is_integer(value), do: 0
  defp non_negative_integer(_value), do: 0

  defp string_value(value) when is_binary(value) and value != "", do: value
  defp string_value(_value), do: nil

  defp number_value(value) when is_number(value), do: value * 1.0
  defp number_value(_value), do: nil
end
