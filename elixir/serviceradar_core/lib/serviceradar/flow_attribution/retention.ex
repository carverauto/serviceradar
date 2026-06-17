defmodule ServiceRadar.FlowAttribution.Retention do
  @moduledoc false

  @schema "platform"
  @table "flow_process_attribution_current"
  @correlation_skew_seconds 900
  @default_retention_minutes 60
  @minimum_retention_minutes div(@correlation_skew_seconds + 59, 60)

  @spec prune() :: {:ok, non_neg_integer()} | {:error, term()}
  def prune do
    sql = """
    WITH deleted_current AS (
      DELETE FROM #{@schema}.#{@table}
      WHERE observed_at < now() - ($1::integer * interval '1 minute')
      RETURNING 1
    )
    SELECT
      (SELECT count(*) FROM deleted_current) AS deleted_count
    """

    case ServiceRadar.Repo.query(sql, [retention_minutes()]) do
      {:ok, %{rows: [[num_rows]]}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec retention_minutes() :: pos_integer()
  def retention_minutes do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.FlowAttribution, [])
    |> Keyword.get(:retention_minutes, @default_retention_minutes)
    |> normalize_retention_minutes()
  end

  defp normalize_retention_minutes(value) when is_integer(value) do
    max(value, @minimum_retention_minutes)
  end

  defp normalize_retention_minutes(_value), do: @default_retention_minutes
end
