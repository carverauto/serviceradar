defmodule ServiceRadarWebNG.SRQL do
  @moduledoc """
  SRQL (ServiceRadar Query Language) module.

  All queries are executed through the Rust NIF which generates parameterized SQL,
  then executed directly via Ecto adapters. No intermediate query layers.
  """

  @behaviour ServiceRadarWebNG.SRQLBehaviour

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.SRQL.EntityAccess
  alias ServiceRadarWebNG.SRQL.Native

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_query_timeout_ms 15_000
  @db_timeout_margin_ms 1_000

  @impl true
  def query(query, opts \\ %{}) when is_binary(query) do
    query_request(%{
      "query" => query,
      "limit" => Map.get(opts, :limit),
      "cursor" => Map.get(opts, :cursor),
      "direction" => Map.get(opts, :direction),
      "mode" => Map.get(opts, :mode),
      "scope" => Map.get(opts, :scope)
    })
  end

  @impl true
  def query_arrow(query, opts \\ %{}) when is_binary(query) do
    limit = Map.get(opts, :limit)
    cursor = Map.get(opts, :cursor)
    direction = Map.get(opts, :direction)
    mode = Map.get(opts, :mode)
    scope = Map.get(opts, :scope)

    with :ok <- EntityAccess.authorize(query, scope),
         {:ok, translation} <- translate(query, limit, cursor, direction, mode),
         {:ok, result} <- execute_translation_raw(translation),
         {:ok, payload} <- encode_result_arrow(result) do
      {:ok,
       %{
         payload: payload,
         schema: %{"columns" => result.columns},
         pagination: build_pagination(translation, result.rows),
         viz: extract_viz(translation)
       }}
    end
  end

  @impl true
  def query_request(%{} = request) do
    case normalize_request(request) do
      {:ok, query, limit, cursor, direction, mode} ->
        execute_query(
          query,
          limit,
          cursor,
          direction,
          mode,
          Map.get(request, "scope") || Map.get(request, :scope)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_query(query, limit, cursor, direction, mode, scope) do
    entity = extract_entity(query)
    start_time = System.monotonic_time()

    result =
      case EntityAccess.authorize(query, scope) do
        {:error, :forbidden} = denied ->
          denied

        :ok ->
          if entity == "dashboards" do
            {:ok,
             %{
               "results" => dashboard_search_rows(scope, query, limit),
               "pagination" => %{"next_cursor" => nil, "previous_cursor" => nil},
               "viz" => nil,
               "error" => nil
             }}
          else
            with {:ok, translation} <- translate(query, limit, cursor, direction, mode) do
              execute_translation(Map.put(translation, "_query", query))
            end
          end
      end

    status = if match?({:ok, _}, result), do: :ok, else: :error
    emit_telemetry(entity, start_time, status)

    result
  end

  defp dashboard_search_rows(scope, query, limit) do
    [ServiceRadarWebNG, Dashboards]
    |> Module.concat()
    |> apply(:search_dashboard_rows, [scope, query, [limit: limit]])
  end

  defp emit_telemetry(entity, start_time, status) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:serviceradar, :srql, :query],
      %{duration: duration},
      %{entity: entity, status: status}
    )
  end

  defp extract_entity(query) when is_binary(query) do
    query = String.trim(query)

    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] ->
        String.downcase(entity)

      nil ->
        query
        |> String.split(~r/[\s|]/, parts: 2)
        |> List.first()
        |> String.downcase()
    end
  end

  defp translate(query, limit, cursor, direction, mode) do
    case Native.translate(query, limit, cursor, direction, mode) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_srql_translate_result, other}}
    end
  end

  defp execute_translation(%{"sql" => sql} = translation) when is_binary(sql) do
    translation
    |> Map.get("params", [])
    |> decode_params()
    |> case do
      {:ok, params} ->
        with {:ok, result} <- run_sql(sql, params) do
          {:ok, build_response(translation, result)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_translation(_translation) do
    {:error, :invalid_srql_translation}
  end

  defp execute_translation_raw(%{"sql" => sql} = translation) when is_binary(sql) do
    translation
    |> Map.get("params", [])
    |> decode_params()
    |> case do
      {:ok, params} -> run_sql(sql, params)
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_translation_raw(_translation) do
    {:error, :invalid_srql_translation}
  end

  @sobelow_skip ["SQL.Query"]
  defp run_sql(sql, params) do
    with :ok <- ensure_read_only_sql(sql) do
      timeout_ms = srql_query_timeout_ms()

      run_transaction(
        fn ->
          statement_timeout = "#{timeout_ms}ms"
          db_timeout_ms = timeout_ms + @db_timeout_margin_ms

          with {:ok, _} <- SQL.query(Repo, session_setup_sql(), [statement_timeout], timeout: db_timeout_ms),
               {:ok, result} <- SQL.query(Repo, sql, params, timeout: db_timeout_ms) do
            result
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout_ms + @db_timeout_margin_ms
      )
    end
  end

  # A dropped pool checkout does not arrive as `{:error, _}`. `DBConnection`
  # raises it — `rollback_or_raise(other) -> raise(other)` — from inside
  # `Repo.transaction/2`, before the transaction fun ever runs. That is why the
  # error branch below never saw a pool timeout, and why the raise escaped all
  # the way out through the LiveView task fan-outs. Convert it into the error
  # tuple every caller in this module already handles.
  #
  # Still logged: with the raise contained, pool exhaustion would otherwise be
  # completely silent, and it is the symptom worth alerting on.
  defp run_transaction(fun, timeout) do
    case Repo.transaction(fun, timeout: timeout) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in DBConnection.ConnectionError ->
      Logger.warning("SRQL query could not obtain a database connection: #{Exception.message(error)}")

      {:error, error}
  catch
    :exit, {:timeout, _} = reason ->
      Logger.warning("SRQL query timed out waiting on the database: #{inspect(reason)}")

      {:error, reason}
  end

  # Transaction-local session settings applied immediately before every SRQL
  # query. Both use `set_config(name, value, is_local = true)`, the `SET LOCAL`
  # form: they are scoped to the enclosing SRQL transaction (see `run_sql/2`) and
  # never leak to unrelated queries sharing the pooled connection.
  #
  #   * `statement_timeout` bounds runaway ad-hoc queries.
  #
  #   * `plan_cache_mode = force_custom_plan` defeats PostgreSQL's generic-plan
  #     trap. Postgrex executes SRQL as *named prepared statements*, so after ~5
  #     executions the cached statement can flip to a generic plan that cannot
  #     estimate parameterized `= ANY($n)` / `IN` selectivity. Custom plans keep
  #     the actual values visible to the planner and remain the correct default
  #     for high-variance SRQL analytics.
  #
  #     Custom planning alone does not make every ordered membership query
  #     indexable. In particular, PostgreSQL cannot preserve effective-timestamp
  #     order across multiple values of the leading `lower(severity_text)` index
  #     key. The SRQL logs compiler handles that sparse top-N shape separately by
  #     merging bounded, scalar equality branches; retaining force_custom_plan
  #     still protects that query and all other parameter-sensitive SRQL shapes
  #     from generic-plan regressions.
  #
  # Applied to *all* SRQL executions, not only queries containing `= ANY(`: SRQL
  # is ad-hoc, high-variance analytics where per-execution custom planning is the
  # correct default. The planning cost is negligible next to the data volumes
  # scanned, whereas a mis-estimated generic plan degrades to a full scan. A
  # shape-sniffing heuristic would be fragile (it would miss other
  # selectivity-sensitive predicates) for no measurable benefit.
  @doc false
  def session_setup_sql do
    "SELECT set_config('statement_timeout', $1, true), " <>
      "set_config('plan_cache_mode', 'force_custom_plan', true)"
  end

  defp srql_query_timeout_ms do
    :serviceradar_web_ng
    |> Application.get_env(:srql_query_timeout_ms, @default_query_timeout_ms)
    |> normalize_positive_integer(@default_query_timeout_ms)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp ensure_read_only_sql(sql) when is_binary(sql) do
    normalized =
      sql
      |> String.trim_leading()
      |> String.trim_trailing(";")

    cond do
      normalized == "" ->
        {:error, :empty_sql}

      String.contains?(normalized, ";") ->
        {:error, :multiple_sql_statements_not_allowed}

      Regex.match?(~r/\A(?:select|with)\b/i, normalized) ->
        :ok

      true ->
        {:error, :non_read_only_sql}
    end
  end

  defp build_response(translation, %Postgrex.Result{columns: columns, rows: rows}) do
    results =
      columns
      |> build_results(rows)
      |> enrich_downsample_aliases(translation)

    viz = extract_viz(translation)
    pagination = build_pagination(translation, results)

    %{
      "results" => results,
      "pagination" => pagination,
      "schema" => %{"columns" => columns},
      "viz" => viz,
      "error" => nil
    }
  end

  defp encode_result_arrow(%Postgrex.Result{columns: columns, rows: rows}) do
    row_maps = build_arrow_rows(columns, rows)

    with {:ok, rows_json} <- Jason.encode(row_maps) do
      Native.encode_arrow_json(columns, rows_json)
    end
  end

  defp build_arrow_rows(columns, rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, normalize_value(val)} end)
    end)
  end

  defp build_results([single], rows) when is_binary(single) do
    Enum.map(rows, fn
      [value] -> normalize_value(value)
      other -> normalize_value(other)
    end)
  end

  defp build_results(columns, rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, normalize_value(val)} end)
      |> normalize_row_aliases()
    end)
  end

  defp extract_viz(translation) do
    case Map.get(translation, "viz") do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp build_pagination(translation, results) do
    limit = pagination_limit(translation)

    %{
      "next_cursor" => next_cursor(translation, limit, results),
      "prev_cursor" => get_in(translation, ["pagination", "prev_cursor"]),
      "limit" => limit
    }
  end

  defp pagination_limit(translation) do
    case get_in(translation, ["pagination", "limit"]) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp next_cursor(translation, limit, results) do
    candidate = get_in(translation, ["pagination", "next_cursor"])

    if is_integer(limit) and is_binary(candidate) and length(results) >= limit do
      candidate
    end
  end

  defp normalize_row_aliases(row) when is_map(row) do
    row
    |> maybe_alias("device_id", "uid")
    |> maybe_alias("type", "device_type")
    |> maybe_alias("first_seen_time", "first_seen")
    |> maybe_alias("last_seen_time", "last_seen")
  end

  defp maybe_alias(row, from, to) do
    cond do
      Map.has_key?(row, to) -> row
      Map.has_key?(row, from) -> Map.put(row, to, Map.get(row, from))
      true -> row
    end
  end

  defp enrich_downsample_aliases(results, translation) when is_list(results) and is_map(translation) do
    query = Map.get(translation, "_query")
    series_field = extract_query_token(query, "series")

    value_field =
      extract_query_token(query, "value_field") || extract_query_token(query, "value-field")

    if is_nil(series_field) and is_nil(value_field) do
      results
    else
      Enum.map(results, fn
        %{} = row ->
          row
          |> maybe_alias("series", series_field)
          |> maybe_alias("value", value_field)

        other ->
          other
      end)
    end
  end

  defp enrich_downsample_aliases(results, _translation), do: results

  defp extract_query_token(query, key) when is_binary(query) and is_binary(key) do
    regex = ~r/(?:^|\s)#{Regex.escape(key)}:([^\s]+)/i

    case Regex.run(regex, query, capture: :all_but_first) do
      [value] ->
        value
        |> String.trim()
        |> String.trim("\"")
        |> case do
          "" -> nil
          v -> v
        end

      _ ->
        nil
    end
  end

  defp extract_query_token(_, _), do: nil

  @doc false
  def encode_result_value(value), do: normalize_value(value)

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_value(%NaiveDateTime{} = value) do
    # Postgrex returns timestamp-without-time-zone as NaiveDateTime. In this
    # schema those columns store UTC. An offset-less ISO string is the same
    # shape as a syslog source wall-clock, so the UI will not localize it.
    value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(%Decimal{} = value), do: Decimal.to_string(value)

  defp normalize_value(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      case Ecto.UUID.load(value) do
        {:ok, uuid} -> uuid
        :error -> Base.encode16(value)
      end
    end
  end

  defp normalize_value(value), do: value

  defp decode_params(params) when is_list(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case decode_param(param) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_params(_), do: {:error, :invalid_srql_params}

  # `@doc false` (rather than `defp`) so `decode_param/1` can be exercised
  # directly by a `:db_free` unit test, matching `session_setup_sql/0` below.
  @doc false
  def decode_param(%{"t" => "text", "v" => value}) when is_binary(value), do: {:ok, value}

  def decode_param(%{"t" => "bool", "v" => value}) when is_boolean(value), do: {:ok, value}
  def decode_param(%{"t" => "int", "v" => value}) when is_integer(value), do: {:ok, value}

  def decode_param(%{"t" => "int_array", "v" => values}) when is_list(values) do
    if Enum.all?(values, &is_integer/1) do
      {:ok, values}
    else
      {:error, :invalid_int_array_param}
    end
  end

  def decode_param(%{"t" => "float", "v" => value}) when is_float(value), do: {:ok, value}
  def decode_param(%{"t" => "float", "v" => value}) when is_integer(value), do: {:ok, value / 1}

  def decode_param(%{"t" => "text_array", "v" => values}) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, :invalid_text_array_param}
    end
  end

  def decode_param(%{"t" => "timestamptz", "v" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamptz_param}
    end
  end

  def decode_param(%{"t" => "date", "v" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date_param}
    end
  end

  def decode_param(%{"t" => "uuid", "v" => value}) when is_binary(value) do
    # UUID is passed as a string, but Postgrex expects 16-byte binary
    # Use Ecto.UUID.dump to convert string to binary format
    case Ecto.UUID.dump(value) do
      {:ok, binary_uuid} -> {:ok, binary_uuid}
      :error -> {:error, :invalid_uuid_param}
    end
  end

  def decode_param(%{"t" => type, "v" => value}) when type in ["inet", "cidr"] and is_binary(value) do
    case ServiceRadar.Types.Cidr.dump_to_native(value, []) do
      {:ok, inet} -> {:ok, inet}
      _ -> {:error, :invalid_inet_param}
    end
  end

  def decode_param(_), do: {:error, :invalid_srql_param}

  defp normalize_request(%{"query" => query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, "limit"))
    cursor = normalize_optional_string(Map.get(request, "cursor"))
    direction = normalize_direction(Map.get(request, "direction"))
    mode = normalize_optional_string(Map.get(request, "mode"))
    {:ok, query, limit, cursor, direction, mode}
  end

  defp normalize_request(%{query: query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, :limit))
    cursor = normalize_optional_string(Map.get(request, :cursor))
    direction = normalize_direction(Map.get(request, :direction))
    mode = normalize_optional_string(Map.get(request, :mode))
    {:ok, query, limit, cursor, direction, mode}
  end

  defp normalize_request(_request) do
    {:error, "missing required field: query"}
  end

  defp parse_limit(nil), do: nil
  defp parse_limit(limit) when is_integer(limit), do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_direction(nil), do: nil

  defp normalize_direction(direction) when direction in ["next", "prev"] do
    direction
  end

  defp normalize_direction(direction) when direction in [:next, :prev] do
    Atom.to_string(direction)
  end

  defp normalize_direction(_direction), do: nil
end
