defmodule ServiceRadar.AnalyticsStore.Head do
  @moduledoc """
  Short-lived Postgrex sessions against the pg_duckdb analytics head.

  Same discard-after-use rule as `ServiceRadar.ColdTier.Head` (a session that
  has seen a DuckDB error can be poisoned). Tests inject `:session`.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Registry.Table
  alias ServiceRadar.ColdTier.Verification

  @temp_table "analytics_batch"
  @s3_secret_prefix "simple_s3_secret"

  @doc "Run `fun` on a fresh head connection."
  @spec session(Config.t(), (pid() -> any())) :: {:ok, any()} | {:error, term()}
  def session(%Config{} = cfg, fun) when is_function(fun, 1) do
    with {:ok, opts} <- Config.head_opts(cfg),
         {:ok, conn} <- Postgrex.start_link(opts) do
      try do
        :ok = maybe_ensure_s3_secret(conn, cfg)
        {:ok, fun.(conn)}
      rescue
        exception -> {:error, exception}
      after
        GenServer.stop(conn, :normal, 5_000)
      end
    end
  end

  @doc "Rebuild hive views for flipped tables on a fresh head session."
  @spec ensure_views(Config.t()) :: {:ok, :ok} | {:error, term()}
  def ensure_views(%Config{} = cfg) do
    session(cfg, fn conn ->
      ServiceRadar.AnalyticsStore.Views.ensure_all(conn, cfg)
    end)
  end

  @doc "DuckDB CREATE SECRET SQL for the configured S3 bucket."
  @spec create_s3_secret_sql(map()) :: String.t()
  def create_s3_secret_sql(s3) when is_map(s3) do
    """
    SELECT duckdb.create_simple_secret(
      type := 'S3',
      key_id := '#{sql_escape(s3.access_key_id || "")}',
      secret := '#{sql_escape(s3.secret_access_key || "")}',
      region := '#{sql_escape(s3.region)}',
      endpoint := '#{sql_escape(s3.endpoint || "")}',
      url_style := '#{sql_escape(s3.url_style)}',
      use_ssl := '#{if s3.use_ssl == false, do: "false", else: "true"}',
      scope := '#{sql_escape(s3.bucket_url)}'
    )
    """
  end

  @doc "CREATE TEMP TABLE matching the registry export columns."
  @spec create_temp_sql(Table.t()) :: String.t()
  def create_temp_sql(%Table{columns: columns}) do
    defs =
      Enum.map_join(columns, ", ", fn {name, type, cast} ->
        "#{quote_ident(name)} #{pg_type(type, cast)}"
      end)

    "CREATE TEMP TABLE #{@temp_table} (#{defs})"
  end

  @doc "Column names in registry order."
  @spec column_names(Table.t()) :: [String.t()]
  def column_names(%Table{columns: columns}), do: Enum.map(columns, fn {name, _, _} -> name end)

  @doc "Row values in registry column order (missing keys become nil)."
  @spec row_values(Table.t(), map()) :: [term()]
  def row_values(%Table{} = entry, row) when is_map(row) do
    Enum.map(column_names(entry), fn name ->
      encode(fetch(row, name), column_cast(entry, name))
    end)
  end

  @doc "INSERT one chunk of rows; returns `{sql, params}`."
  @spec insert_sql(Table.t(), [map()]) :: {String.t(), [term()]}
  def insert_sql(%Table{} = entry, rows) when is_list(rows) and rows != [] do
    names = column_names(entry)
    cols = Enum.map_join(names, ", ", &quote_ident/1)
    width = length(names)

    {placeholders, params, _} =
      Enum.reduce(rows, {[], [], 1}, fn row, {ph_acc, param_acc, idx} ->
        values = row_values(entry, row)
        ph = Enum.map_join(0..(width - 1), ",", fn i -> "$#{idx + i}" end)
        {["(#{ph})" | ph_acc], Enum.reverse(values, param_acc), idx + width}
      end)

    sql =
      "INSERT INTO #{@temp_table} (#{cols}) VALUES " <>
        Enum.join(Enum.reverse(placeholders), ", ")

    {sql, Enum.reverse(params)}
  end

  @doc "COPY the temp table to a Parquet URL, ordered by time + tiebreakers."
  @spec copy_sql(Table.t(), String.t()) :: String.t()
  def copy_sql(%Table{} = entry, target_url) when is_binary(target_url) do
    select = Registry.export_select_list(entry)
    order = order_clause(entry)

    """
    COPY (
      SELECT #{select}
      FROM #{@temp_table}
      #{order}
    ) TO '#{escape(target_url)}' (FORMAT parquet, COMPRESSION zstd)
    """
  end

  @spec verify_sql(Table.t(), String.t()) :: String.t()
  def verify_sql(%Table{} = entry, target_url) when is_binary(target_url) do
    Verification.parquet_sql(entry, escape(target_url))
  end

  defp order_clause(%Table{time_column: time, tiebreakers: ties}) do
    cols = [time | ties]
    "ORDER BY " <> Enum.map_join(cols, ", ", &quote_ident/1)
  end

  defp column_cast(%Table{columns: columns}, name) do
    case Enum.find(columns, fn {n, _, _} -> n == name end) do
      {_, _, cast} -> cast
      nil -> :none
    end
  end

  defp fetch(row, name) do
    Map.get(row, name) || (safe_atom(name) && Map.get(row, safe_atom(name)))
  end

  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp encode(nil, _), do: nil
  defp encode(%DateTime{} = dt, _), do: dt
  defp encode(value, :text) when is_map(value) or is_list(value), do: JSON.encode!(value)
  defp encode(value, _), do: value

  defp pg_type(_type, :text), do: "text"
  defp pg_type("jsonb", _), do: "text"
  defp pg_type("uuid", _), do: "text"
  defp pg_type(type, _), do: type

  defp quote_ident(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
  defp escape(url), do: String.replace(url, "'", "''")

  defp maybe_ensure_s3_secret(conn, cfg) do
    case Config.s3_secret(cfg) do
      :disabled -> :ok
      {:ok, s3} -> ensure_s3_secret(conn, s3)
    end
  end

  defp ensure_s3_secret(conn, s3) do
    %Postgrex.Result{rows: rows} =
      query!(conn, """
      SELECT srvname FROM pg_foreign_server WHERE srvname LIKE '#{@s3_secret_prefix}%'
      """)

    for [srvname] <- rows do
      query!(conn, ~s(DROP SERVER IF EXISTS "#{srvname}" CASCADE))
    end

    query!(conn, create_s3_secret_sql(s3))
    :ok
  end

  defp query!(conn, sql, params \\ []) do
    Postgrex.query!(conn, sql, params, timeout: :infinity)
  end

  defp sql_escape(nil), do: ""
  defp sql_escape(value) when is_boolean(value), do: to_string(value)
  defp sql_escape(value), do: String.replace(to_string(value), "'", "''")
end
