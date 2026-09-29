defmodule ServiceRadar.Observability.TelemetryIndexRead do
  @moduledoc """
  Manual read action behind the JSON:API telemetry `index` routes.

  Each dataset is read from the backend that is still receiving its rows.
  With `analytics.starrocks.enabled` off, the read delegates to the resource's
  CNPG data layer query unchanged. With it on, a dataset whose writes have
  moved to the warehouse is served from its warehouse table: OTel metric
  samples and points, and OTel traces and summaries, follow the enabled flag,
  while logs and raw and hourly timeseries metrics follow the per-dataset
  cutover list, so a row still written to CNPG is still read from CNPG and a
  `/api/v2` telemetry route never serves history frozen at the switch. A
  dataset with no warehouse table (the interface/disk hourly aggregates and
  the legacy sysmon tables retired under #4861) stays CNPG-backed, because
  its rows are still written to CNPG.

  The Frontend is queried over the MySQL text protocol, which takes no bind
  parameters, so filter values and pagination bounds reach it as literals.
  Every value is therefore rendered from a closed set of shapes: a string is
  backslash-and-quote escaped, a number or boolean is printed literally, and a
  `DateTime` is rendered as the UTC wall clock the warehouse stores. A filter
  or sort on a column the warehouse table does not store, or a filter
  operator or value shape this module does not render, is an
  `Ash.Error.Query.InvalidQuery`, never a dropped clause.

  Test seams live in the query context: `:cnpg_read` replaces the data-layer
  run, `:cnpg_count` replaces the CNPG count query, and `:starrocks_query`
  replaces `ServiceRadar.Analytics.StarRocks.Query.execute/1`.

  The offset page's total count is computed when the client requests it
  (`page[count]`), with a `COUNT(*)` query against the active backend, so the
  JSON:API response keeps `meta.total` and the `last` link.
  """

  use Ash.Resource.ManualRead

  alias Ash.Error.Query.InvalidQuery
  alias Ash.Query.Ref
  alias Ash.Resource.Info
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
    "otel_metrics" => ~w(timestamp trace_id span_id service_name span_name span_kind duration_ms
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
      ~w(bucket device_id metric_type metric_name avg_value min_value max_value sample_count)a,
    "otel_traces" => ~w(trace_id span_id timestamp parent_span_id trace_state name kind
         start_time_unix_nano end_time_unix_nano service_name service_version
         service_instance service_namespace deployment_environment scope_name
         scope_version scope_attributes status_code status_message attributes
         resource_attributes events links dropped_attributes_count
         dropped_events_count dropped_links_count created_at ingest_identity
         ingest_agent_id ingest_partition)a,
    "otel_trace_summaries" => ~w(trace_id timestamp root_span_id root_span_name root_service_name
         root_service_namespace deployment_environment root_span_kind
         start_time_unix_nano end_time_unix_nano duration_ms status_code
         status_message service_set span_count error_count)a
  }

  @dataset_for_table %{
    "logs" => :logs,
    "otel_metrics" => :otel_metrics,
    "otel_metric_points" => :otel_metrics,
    "timeseries_metrics" => :metrics,
    "timeseries_metrics_hourly" => :metrics,
    "otel_traces" => :otel_traces,
    "otel_trace_summaries" => :otel_traces
  }

  @impl Ash.Resource.ManualRead
  def read(query, data_layer_query, opts, _context) do
    case mode(query.resource, opts) do
      :cnpg ->
        run_cnpg(query, data_layer_query)

      {:starrocks, table} ->
        query
        |> run_warehouse(table, opts)
        |> present_warehouse_error()
    end
  end

  defp present_warehouse_error({:error, {:unsupported_warehouse_filter_field, field}}) do
    {:error, invalid_query(field, "unsupported filter field #{field_label(field)}")}
  end

  defp present_warehouse_error({:error, :relationship_filter_unsupported}) do
    {:error, invalid_query(nil, "relationship filters are not supported")}
  end

  defp present_warehouse_error({:error, {:unsupported_warehouse_filter, :empty_in}}) do
    {:error, invalid_query(nil, "in filter requires a non-empty set")}
  end

  defp present_warehouse_error({:error, {:unsupported_warehouse_filter, detail}}) do
    {:error, invalid_query(nil, "unsupported filter #{field_label(detail)}")}
  end

  defp present_warehouse_error({:error, {:unsupported_warehouse_value, value}}) do
    {:error, invalid_query(nil, "unsupported filter value #{inspect(value)}")}
  end

  defp present_warehouse_error({:error, {:unsupported_warehouse_sort_field, field}}) do
    {:error, invalid_query(field, "unsupported sort field #{field_label(field)}")}
  end

  defp present_warehouse_error({:error, :relationship_sort_unsupported}) do
    {:error, invalid_query(nil, "relationship sorts are not supported")}
  end

  defp present_warehouse_error({:error, {:unsupported_warehouse_sort, detail}}) do
    {:error, invalid_query(nil, "unsupported sort #{field_label(detail)}")}
  end

  defp present_warehouse_error(result), do: result

  defp invalid_query(field, message) when is_atom(field) do
    InvalidQuery.exception(field: field, message: message)
  end

  defp invalid_query(_field, message) do
    InvalidQuery.exception(message: message)
  end

  defp field_label(field) when is_atom(field), do: Atom.to_string(field)
  defp field_label(other), do: inspect(other)

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
    case_result =
      case query.context[:cnpg_read] do
        fun when is_function(fun, 1) -> fun.(data_layer_query)
        _ -> Ash.DataLayer.run_query(data_layer_query, query.resource)
      end

    maybe_add_cnpg_count(case_result, query)
  end

  defp maybe_add_cnpg_count({:ok, records}, query) do
    if count_needed?(query) do
      with {:ok, full_count} <- cnpg_full_count(query) do
        {:ok, records, %{full_count: full_count}}
      end
    else
      {:ok, records}
    end
  end

  defp maybe_add_cnpg_count(other, _query), do: other

  defp cnpg_full_count(query) do
    case query.context[:cnpg_count] do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        count_query =
          Ash.Query.unset(query, [:sort, :distinct_sort, :lock, :load, :limit, :offset, :page])

        with {:ok, data_layer_query} <- Ash.Query.data_layer_query(count_query),
             {:ok, aggregate} <-
               Ash.Query.Aggregate.new(query.resource, :count, :count, tenant: query.tenant),
             {:ok, %{count: count}} <-
               Ash.DataLayer.run_aggregate_query(data_layer_query, [aggregate], query.resource) do
          {:ok, count}
        end
    end
  end

  defp count_needed?(%{page: page}) when is_list(page), do: page[:count] == true
  defp count_needed?(_query), do: false

  defp run_warehouse(query, table, opts) do
    select_attributes = select_attributes(query.resource, table)
    available = Map.fetch!(@warehouse_columns, table)

    with {:ok, where} <- where_clause(query.filter, available),
         {:ok, order} <- order_clause(query.sort, available) do
      sql = build_sql(table, select_attributes, where, order, query.limit, query.offset)

      case execute_warehouse(sql, query.context, opts) do
        {:ok, %{columns: columns, rows: rows}} when is_list(rows) ->
          records = build_records(query.resource, select_attributes, columns, rows)

          if count_needed?(query) do
            with {:ok, full_count} <- full_count(table, where, query, opts) do
              {:ok, records, %{full_count: full_count}}
            end
          else
            {:ok, records}
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
    |> Info.attributes()
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
      context[:starrocks_query] || Keyword.get(opts, :starrocks_query) || (&Query.execute/1)

    starrocks_query.(sql)
  end

  # ---------------------------------------------------------------------------
  # Result shaping
  # ---------------------------------------------------------------------------

  defp build_records(resource, select_attributes, columns, rows) do
    attributes = Info.attributes(resource)
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

      resource
      |> struct(attrs)
      |> Map.put(:__meta__, %Ecto.Schema.Metadata{state: :loaded, schema: resource})
    end)
  end

  defp to_existing_atom(column) when is_atom(column), do: column

  defp to_existing_atom(column) when is_binary(column) do
    String.to_existing_atom(column)
  end

  defp normalize_value(%{type: type}, value) do
    case short_type(type) do
      short when short in [:utc_datetime_usec, :utc_datetime, :datetime] ->
        cast_datetime(value)

      :boolean ->
        cast_boolean(value)

      :float ->
        cast_float(value)

      :integer ->
        cast_integer(value)

      :map ->
        decode_document(value)

      {:array, _inner} ->
        decode_document(value)

      _other ->
        value
    end
  end

  defp short_type({:array, inner}), do: {:array, short_type(inner)}

  defp short_type(type) when is_atom(type) do
    Enum.find_value(Ash.Type.short_names(), type, fn {short, module} ->
      if module == type, do: short
    end)
  end

  defp short_type(type), do: type

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
    do: render_where(expression, available)

  defp where_clause(expression, available), do: render_where(expression, available)

  defp render_where(expression, available) do
    case expression_sql(expression, available) do
      {:ok, nil} -> {:ok, nil}
      {:ok, sql} -> {:ok, "WHERE " <> sql}
      {:error, reason} -> {:error, reason}
    end
  end

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
        :is_nil -> null_check_sql(column, right)
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

  defp null_check_sql(column, true), do: {:ok, "#{column} IS NULL"}
  defp null_check_sql(column, false), do: {:ok, "#{column} IS NOT NULL"}
  defp null_check_sql(_column, _right), do: {:error, {:unsupported_warehouse_filter, :is_nil}}

  defp in_sql(column, %MapSet{} = values), do: in_sql(column, MapSet.to_list(values))

  defp in_sql(column, values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
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

  defp column_sql(%Ref{} = ref, available) do
    cond do
      ref.relationship_path != [] ->
        {:error, :relationship_filter_unsupported}

      Ref.name(ref) in available ->
        {:ok, "`#{Ref.name(ref)}`"}

      true ->
        {:error, {:unsupported_warehouse_filter_field, Ref.name(ref)}}
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
    sort
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
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

  defp sort_field_sql(%Ref{} = ref, direction, available) do
    cond do
      ref.relationship_path != [] ->
        {:error, :relationship_sort_unsupported}

      Ref.name(ref) in available ->
        {:ok, "`#{Ref.name(ref)}` #{direction_sql(direction)}"}

      true ->
        {:error, {:unsupported_warehouse_sort_field, Ref.name(ref)}}
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
