defmodule ServiceRadar.Observability.TelemetryIndexRead do
  @moduledoc """
  Manual read action behind the JSON:API telemetry `index` routes.

  Exactly one telemetry backend is active. With `analytics.starrocks.enabled`
  off, the read delegates to the resource's CNPG data layer query unchanged.
  With it on, a dataset whose writes have moved to the warehouse is served from
  its warehouse table: OTel metric samples and points follow the enabled flag,
  while logs and raw and hourly timeseries metrics follow the per-dataset
  cutover list, so a row still written to CNPG is still read from CNPG and a
  `/api/v2` telemetry route never serves history frozen at the switch. A
  dataset with no warehouse table yet (OTel traces and summaries, the
  interface/disk hourly aggregates, and the legacy sysmon tables retired under
  #4861) stays CNPG-backed, because its rows are still written to CNPG, until
  a warehouse reader and writer land.

  The Frontend is queried over the MySQL text protocol, which takes no bind
  parameters, so filter values and pagination bounds reach it as literals.
  Every value is therefore rendered from a closed set of shapes: a string is
  backslash-and-quote escaped, a number or boolean is printed literally, and a
  `DateTime` is rendered as the UTC wall clock the warehouse stores. A filter
  operator, sort field or value shape this module does not render is an error,
  never a dropped clause.

  Test seams live in the query context: `:cnpg_read` replaces the data-layer
  run, and `:starrocks_query` replaces `ServiceRadar.Analytics.StarRocks.Query.execute/1`.

  The offset page's total count is computed with a separate `COUNT(*)` query
  over the same filter, so the JSON:API response keeps `meta.total` and the
  `last` link.
  """

  use Ash.Resource.ManualRead

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Readers

  # table name -> the subset of the resource's attribute names that warehouse
  # table actually stores. Only these are selected; every other attribute stays
  # nil, exactly as it would be for a CNPG column the warehouse does not hold.
  @warehouse_columns %{
    "logs" =>
      ~w(id timestamp observed_timestamp trace_id span_id severity_text severity_number body
         event_name source source_ip service_name service_version ingest_identity
         ingest_agent_id ingest_partition)a,
    "otel_metrics" =>
      ~w(timestamp trace_id span_id service_name span_name span_kind duration_ms
         duration_seconds metric_type http_method http_route http_status_code grpc_service
         grpc_method grpc_status_code is_slow component level unit ingest_identity
         ingest_agent_id ingest_partition created_at)a,
    "otel_metric_points" =>
      ~w(timestamp metric_name metric_type unit temporality is_monotonic service_name
         attributes attributes_hash value count sum bucket_counts explicit_bounds
         start_time_unix_nano scope_name service_instance_id ingest_identity
         ingest_agent_id ingest_partition created_at)a,
    "timeseries_metrics" =>
      ~w(timestamp gateway_id series_key agent_id metric_name metric_type device_id value
         unit if_index partition scale is_delta counter_width target_device_ip tags)a,
    "timeseries_metrics_hourly" =>
      ~w(bucket device_id metric_type metric_name avg_value min_value max_value sample_count)a
  }

  @dataset_for_table %{
    "logs" => :logs,
    "otel_metrics" => :otel_metrics,
    "otel_metric_points" => :otel_metrics,
    "timeseries_metrics" => :metrics,
    "timeseries_metrics_hourly" => :metrics
  }

  @impl Ash.Resource.ManualRead
  def read(query, data_layer_query, opts, _context) do
    case mode(query.resource, opts) do
      :cnpg ->
        run_cnpg(query, data_layer_query)

      {:starrocks, table} ->
        run_warehouse(query, table, opts)
    end
  end

  @doc false
  @spec mode(module(), keyword()) :: :cnpg | {:starrocks, String.t()}
  def mode(_resource, opts) do
    case Keyword.get(opts, :table) do
      table when is_binary(table) ->
        if Readers.mode_for(Map.fetch!(@dataset_for_table, table)) == "starrocks" do
          {:starrocks, table}
        else
          :cnpg
        end

      _ ->
        :cnpg
    end
  end

  defp run_cnpg(query, data_layer_query) do
    case query.context[:cnpg_read] do
      fun when is_function(fun, 1) -> fun.(data_layer_query)
      _ -> Ash.DataLayer.run_query(data_layer_query, query.resource)
    end
  end

  defp run_warehouse(query, table, opts) do
    select_attributes = select_attributes(query.resource, table)
    available = Map.fetch!(@warehouse_columns, table)

    with {:ok, where} <- where_clause(query.filter, available),
         {:ok, order} <- order_clause(query.sort, available) do
      sql = build_sql(table, select_attributes, where, order, query.limit, query.offset)

      case execute_warehouse(sql, query.context, opts) do
        {:ok, %{columns: columns, rows: rows}} when is_list(rows) ->
          records = build_records(query.resource, select_attributes, columns, rows)

          with {:ok, full_count} <- full_count(table, where, query, opts) do
            {:ok, records, %{full_count: full_count}}
          end

        {:ok, other} ->
          {:error, {:unexpected_starrocks_result, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp full_count(table, where, query, opts) do
    sql =
      ["SELECT", "COUNT(*)", "FROM", Env.table(table), where]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    case execute_warehouse(sql, query.context, opts) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 ->
        {:ok, count}

      {:ok, other} ->
        {:error, {:unexpected_starrocks_count_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_attributes(resource, table) do
    available = Map.fetch!(@warehouse_columns, table)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&(&1.name in available))
  end

  defp build_sql(table, select_attributes, where, order, limit, offset) do
    [
      "SELECT",
      Enum.map_join(select_attributes, ", ", &"`#{&1.name}`"),
      "FROM",
      Env.table(table),
      where,
      order,
      limit_offset_sql(limit, offset)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp execute_warehouse(sql, context, opts) do
    starrocks_query =
      context[:starrocks_query] || Keyword.get(opts, :starrocks_query) || &Query.execute/1

    starrocks_query.(sql)
  end

  # ---------------------------------------------------------------------------
  # Result shaping
  # ---------------------------------------------------------------------------

  defp build_records(resource, select_attributes, columns, rows) do
    attributes = Ash.Resource.Info.attributes(resource)
    by_name = Map.new(select_attributes, &{&1.name, &1})

    Enum.map(rows, fn row ->
      values =
        columns
        |> Enum.zip(row)
        |> Enum.reduce(%{}, fn {column, value}, acc ->
          name = to_existing_atom(column)

          case Map.fetch(by_name, name) do
            {:ok, attribute} -> Map.put(acc, name, normalize_value(attribute, value))
            :error -> acc
          end
        end)

      # Every attribute is present, nil when the warehouse column is absent, so
      # `struct/2` always satisfies the resource's enforced keys (for example
      # `timeseries_metrics` does not store `created_at`).
      attrs =
        Enum.reduce(attributes, %{}, fn attribute, acc ->
          Map.put(acc, attribute.name, Map.get(values, attribute.name))
        end)

      struct(resource, attrs)
      |> Map.put(:__meta__, %Ecto.Schema.Metadata{state: :loaded, schema: resource})
    end)
  end

  defp to_existing_atom(column) when is_atom(column), do: column

  defp to_existing_atom(column) when is_binary(column) do
    String.to_existing_atom(column)
  end

  defp normalize_value(%{type: type}, value)
       when type in [:utc_datetime_usec, :utc_datetime, :datetime] do
    cast_datetime(value)
  end

  defp normalize_value(%{type: :boolean}, value), do: cast_boolean(value)
  defp normalize_value(%{type: :float}, value), do: cast_float(value)
  defp normalize_value(%{type: :integer}, value), do: cast_integer(value)
  defp normalize_value(%{type: :map}, value), do: decode_document(value)
  defp normalize_value(%{type: {:array, _type}}, value), do: decode_document(value)
  defp normalize_value(_attribute, value), do: value

  defp cast_datetime(%DateTime{} = value), do: value |> utc() |> usec()
  defp cast_datetime(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> usec()

  defp cast_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        cast_datetime(datetime)

      {:error, _reason} ->
        case value |> String.replace(" ", "T", global: false) |> NaiveDateTime.from_iso8601() do
          {:ok, naive} -> cast_datetime(naive)
          {:error, _reason} -> value
        end
    end
  end

  defp cast_datetime(value), do: value

  defp utc(%DateTime{} = value), do: DateTime.shift_zone!(value, "Etc/UTC")
  defp usec(%DateTime{microsecond: {us, _precision}} = value), do: %{value | microsecond: {us, 6}}

  defp cast_boolean(value) when is_boolean(value), do: value
  defp cast_boolean(value) when value in [1, "1", "true"], do: true
  defp cast_boolean(value) when value in [0, "0", "false"], do: false
  defp cast_boolean(value), do: value

  defp cast_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp cast_float(value) when is_float(value), do: value
  defp cast_float(value) when is_integer(value), do: value / 1

  defp cast_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp cast_float(value), do: value

  defp cast_integer(value) when is_integer(value), do: value

  defp cast_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp cast_integer(value), do: value

  defp decode_document(nil), do: nil

  defp decode_document(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp decode_document(value), do: value

  # ---------------------------------------------------------------------------
  # Filter, sort and pagination rendering
  # ---------------------------------------------------------------------------

  defp where_clause(nil, _available), do: {:ok, nil}

  defp where_clause(%Ash.Filter{expression: expression}, available),
    do: expression_sql(expression, available)

  defp where_clause(expression, available), do: expression_sql(expression, available)

  defp expression_sql(true, _available), do: {:ok, nil}
  defp expression_sql(false, _available), do: {:ok, "1 = 0"}
  defp expression_sql(nil, _available), do: {:ok, nil}

  defp expression_sql(%Ash.Query.BooleanExpression{op: op, left: left, right: right}, available)
       when op in [:and, :or] do
    with {:ok, left_sql} <- expression_sql(left, available),
         {:ok, right_sql} <- expression_sql(right, available) do
      {:ok, "(#{left_sql} #{String.upcase(to_string(op))} #{right_sql})"}
    end
  end

  defp expression_sql(%Ash.Query.Not{expression: expression}, available) do
    with {:ok, sql} <- expression_sql(expression, available) do
      {:ok, "NOT (#{sql})"}
    end
  end

  defp expression_sql(%{__operator__?: true} = predicate, available),
    do: operator_sql(predicate, available)

  defp expression_sql(other, _available), do: {:error, {:unsupported_warehouse_filter, other}}

  defp operator_sql(%{operator: op, left: left, right: right}, available) do
    with {:ok, column} <- column_sql(left, available) do
      case op do
        :== -> equality_sql(column, "=", right)
        :!= -> equality_sql(column, "!=", right)
        :> -> comparison_sql(column, ">", right)
        :>= -> comparison_sql(column, ">=", right)
        :< -> comparison_sql(column, "<", right)
        :<= -> comparison_sql(column, "<=", right)
        :in -> in_sql(column, right)
        :is_nil -> is_nil_sql(column, right)
        _ -> {:error, {:unsupported_warehouse_filter, op}}
      end
    end
  end

  defp equality_sql(column, "=", nil), do: {:ok, "#{column} IS NULL"}
  defp equality_sql(column, "!=", nil), do: {:ok, "#{column} IS NOT NULL"}
  defp equality_sql(column, operator, value), do: comparison_sql(column, operator, value)

  defp comparison_sql(column, operator, value) do
    case literal_sql(value) do
      {:ok, literal} -> {:ok, "#{column} #{operator} #{literal}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp is_nil_sql(column, true), do: {:ok, "#{column} IS NULL"}
  defp is_nil_sql(column, false), do: {:ok, "#{column} IS NOT NULL"}
  defp is_nil_sql(_column, _right), do: {:error, {:unsupported_warehouse_filter, :is_nil}}

  defp in_sql(column, values) when is_list(values) and values != [] do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case literal_sql(value) do
        {:ok, literal} -> {:cont, {:ok, [literal | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, literals} -> {:ok, "#{column} IN (#{literals |> Enum.reverse() |> Enum.join(", ")})"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp in_sql(_column, _values), do: {:error, {:unsupported_warehouse_filter, :empty_in}}

  defp column_sql(%Ash.Query.Ref{} = ref, available) do
    cond do
      ref.relationship_path != [] ->
        {:error, :relationship_filter_unsupported}

      Ash.Query.Ref.name(ref) in available ->
        {:ok, "`#{Ash.Query.Ref.name(ref)}`"}

      true ->
        {:error, {:unsupported_warehouse_filter_field, Ash.Query.Ref.name(ref)}}
    end
  end

  defp column_sql(%{name: name}, available) when is_atom(name) do
    if name in available do
      {:ok, "`#{name}`"}
    else
      {:error, {:unsupported_warehouse_filter_field, name}}
    end
  end

  defp column_sql(other, _available), do: {:error, {:unsupported_warehouse_filter_field, other}}

  defp literal_sql(value) when is_binary(value), do: {:ok, "'#{escape_string(value)}'"}
  defp literal_sql(value) when is_integer(value), do: {:ok, Integer.to_string(value)}

  defp literal_sql(value) when is_float(value),
    do: {:ok, :erlang.float_to_binary(value, [:short])}

  defp literal_sql(true), do: {:ok, "TRUE"}
  defp literal_sql(false), do: {:ok, "FALSE"}
  defp literal_sql(%Decimal{} = value), do: {:ok, Decimal.to_string(value)}
  defp literal_sql(%DateTime{} = value), do: {:ok, "'#{datetime_literal(value)}'"}
  defp literal_sql(%NaiveDateTime{} = value), do: {:ok, "'#{datetime_literal(value)}'"}

  defp literal_sql(nil), do: {:ok, "NULL"}

  defp literal_sql(other), do: {:error, {:unsupported_warehouse_value, other}}

  defp escape_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp datetime_literal(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> NaiveDateTime.to_string()
  end

  defp datetime_literal(%NaiveDateTime{} = value), do: NaiveDateTime.to_string(value)

  defp order_clause(nil, _available), do: {:ok, nil}
  defp order_clause([], _available), do: {:ok, nil}

  defp order_clause(sort, available) when is_list(sort) do
    Enum.reduce_while(sort, {:ok, []}, fn entry, {:ok, acc} ->
      case sort_entry_sql(entry, available) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, "ORDER BY " <> Enum.join(Enum.reverse(parts), ", ")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sort_entry_sql({field, direction}, available),
    do: sort_field_sql(field, direction, available)

  defp sort_entry_sql(field, available) when is_atom(field),
    do: sort_field_sql(field, :asc, available)

  defp sort_entry_sql(other, _available), do: {:error, {:unsupported_warehouse_sort, other}}

  defp sort_field_sql(field, direction, available) when is_atom(field) do
    if field in available do
      {:ok, "`#{field}` #{direction_sql(direction)}"}
    else
      {:error, {:unsupported_warehouse_sort_field, field}}
    end
  end

  defp sort_field_sql(%Ash.Query.Ref{} = ref, direction, available) do
    cond do
      ref.relationship_path != [] ->
        {:error, :relationship_sort_unsupported}

      Ash.Query.Ref.name(ref) in available ->
        {:ok, "`#{Ash.Query.Ref.name(ref)}` #{direction_sql(direction)}"}

      true ->
        {:error, {:unsupported_warehouse_sort_field, Ash.Query.Ref.name(ref)}}
    end
  end

  defp sort_field_sql(other, _direction, _available),
    do: {:error, {:unsupported_warehouse_sort_field, other}}

  defp direction_sql(direction) when direction in [:asc, :asc_nulls_first, :asc_nulls_last],
    do: "ASC"

  defp direction_sql(direction) when direction in [:desc, :desc_nulls_first, :desc_nulls_last],
    do: "DESC"

  defp direction_sql(_direction), do: "ASC"

  defp limit_offset_sql(limit, offset) do
    parts =
      []
      |> maybe_prepend(is_integer(limit) and limit >= 0, "LIMIT #{limit}")
      |> maybe_prepend(is_integer(offset) and offset > 0, "OFFSET #{offset}")

    case parts do
      [] -> nil
      _ -> Enum.join(parts, " ")
    end
  end

  defp maybe_prepend(acc, true, part), do: acc ++ [part]
  defp maybe_prepend(acc, false, _part), do: acc
end
