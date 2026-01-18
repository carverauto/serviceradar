defmodule ServiceRadarWebNG.SRQL.AshAdapter do
  @moduledoc """
  Adapter for routing SRQL queries to Ash resources.

  This adapter intercepts SRQL queries for certain entities and routes them
  through Ash resources instead of the SQL path. This provides:

  - Policy enforcement via Ash.Policy.Authorizer
  - Consistent authorization across web and API

  This is a single-deployment instance UI. Schema context is implicit from
  PostgreSQL search_path set by infrastructure.

  ## Supported Entities

  All SRQL entities are now routed through Ash:

  ### Inventory Domain
  - `devices` -> ServiceRadar.Inventory.Device

  ### Infrastructure Domain
  - `gateways` -> ServiceRadar.Infrastructure.Gateway
  - `agents` -> ServiceRadar.Infrastructure.Agent

  ### Monitoring Domain
  - `events` -> ServiceRadar.Monitoring.OcsfEvent
  - `alerts` -> ServiceRadar.Monitoring.Alert
  - `services` / `service_checks` -> ServiceRadar.Monitoring.ServiceCheck

  ### Observability Domain
  - `logs` -> ServiceRadar.Observability.Log
  - `timeseries_metrics` -> ServiceRadar.Observability.TimeseriesMetric
  - `snmp_metrics` -> ServiceRadar.Observability.TimeseriesMetric
  - `cpu_metrics` -> ServiceRadar.Observability.CpuMetric
  - `memory_metrics` -> ServiceRadar.Observability.MemoryMetric
  - `disk_metrics` -> ServiceRadar.Observability.DiskMetric
  - `otel_metrics` -> ServiceRadar.Observability.OtelMetric
  - `otel_traces` -> ServiceRadar.Observability.OtelTrace
  - `otel_trace_summaries` -> ServiceRadar.Observability.OtelTraceSummary

  ALL entities are routed through Ash - no exceptions. OTel resources use
  `migrate?: false` to prevent Ash from generating migrations for the
  TimescaleDB hypertables/views which have special schemas.

  ## Usage

  The adapter is called by the SRQL module when the feature flag is enabled:

      # In config/config.exs
      config :serviceradar_web_ng, :feature_flags,
        ash_srql_adapter: true

  Queries include the actor for policy enforcement:

      AshAdapter.query("devices", %{filters: [...], sort: [...], limit: 100}, actor)
  """

  require Logger
  require Ash.Query
  import Ash.Expr

  # ALL entities are routed through Ash - no exceptions
  @ash_entities ~w(
    devices gateways agents events alerts services service_checks
    logs timeseries_metrics cpu_metrics memory_metrics disk_metrics
    snmp_metrics rperf_metrics process_metrics
    otel_metrics otel_traces otel_trace_summaries
  )

  # Entity to Ash resource mapping
  @entity_resource_map %{
    # Inventory domain
    "devices" => ServiceRadar.Inventory.Device,
    # Infrastructure domain
    "gateways" => ServiceRadar.Infrastructure.Gateway,
    "agents" => ServiceRadar.Infrastructure.Agent,
    # Monitoring domain
    "events" => ServiceRadar.Monitoring.OcsfEvent,
    "alerts" => ServiceRadar.Monitoring.Alert,
    "services" => ServiceRadar.Monitoring.ServiceCheck,
    "service_checks" => ServiceRadar.Monitoring.ServiceCheck,
    # Observability domain
    "logs" => ServiceRadar.Observability.Log,
    "timeseries_metrics" => ServiceRadar.Observability.TimeseriesMetric,
    "snmp_metrics" => ServiceRadar.Observability.TimeseriesMetric,
    "rperf_metrics" => ServiceRadar.Observability.TimeseriesMetric,
    "process_metrics" => ServiceRadar.Observability.ProcessMetric,
    "cpu_metrics" => ServiceRadar.Observability.CpuMetric,
    "memory_metrics" => ServiceRadar.Observability.MemoryMetric,
    "disk_metrics" => ServiceRadar.Observability.DiskMetric,
    # OTel resources
    "otel_metrics" => ServiceRadar.Observability.OtelMetric,
    "otel_traces" => ServiceRadar.Observability.OtelTrace,
    "otel_trace_summaries" => ServiceRadar.Observability.OtelTraceSummary
  }

  # Entity to domain mapping
  @entity_domain_map %{
    # Inventory domain
    "devices" => ServiceRadar.Inventory,
    # Infrastructure domain
    "gateways" => ServiceRadar.Infrastructure,
    "agents" => ServiceRadar.Infrastructure,
    # Monitoring domain
    "events" => ServiceRadar.Monitoring,
    "alerts" => ServiceRadar.Monitoring,
    "services" => ServiceRadar.Monitoring,
    "service_checks" => ServiceRadar.Monitoring,
    # Observability domain
    "logs" => ServiceRadar.Observability,
    "timeseries_metrics" => ServiceRadar.Observability,
    "snmp_metrics" => ServiceRadar.Observability,
    "rperf_metrics" => ServiceRadar.Observability,
    "process_metrics" => ServiceRadar.Observability,
    "cpu_metrics" => ServiceRadar.Observability,
    "memory_metrics" => ServiceRadar.Observability,
    "disk_metrics" => ServiceRadar.Observability,
    # OTel resources
    "otel_metrics" => ServiceRadar.Observability,
    "otel_traces" => ServiceRadar.Observability,
    "otel_trace_summaries" => ServiceRadar.Observability
  }

  # Field name mapping from SRQL to Ash attribute names
  # SRQL uses Go/SQL conventions, Ash uses Elixir conventions
  @field_mappings %{
    # Devices: Map OCSF field names
    "devices" => %{
      "last_seen" => "last_seen_time",
      "first_seen" => "first_seen_time",
      "created" => "created_time",
      "modified" => "modified_time",
      "timestamp" => "last_seen_time",
      "created_at" => "created_time"
    },
    # Agents: Map time fields
    "agents" => %{
      "timestamp" => "last_seen_time",
      "last_seen" => "last_seen_time",
      "first_seen" => "first_seen_time",
      "created" => "created_time",
      "created_at" => "created_time",
      "modified" => "modified_time"
    },
    # Gateways: Map time fields
    "gateways" => %{
      "timestamp" => "last_seen",
      "created_at" => "first_registered"
    },
    # Events: SRQL uses CloudEvents-style fields, OCSF uses different names
    "events" => %{
      "event_timestamp" => "time",
      "timestamp" => "time",
      "type" => "activity_name",
      "event_type" => "log_name",
      "source" => "log_provider",
      "severity" => "severity",
      "level" => "severity",
      "id" => "id",
      "created_at" => "created_at"
    },
    # ServiceChecks (services): Map SRQL service_status to service_checks
    "services" => %{
      "timestamp" => "last_check_at",
      "service_name" => "name",
      "service_type" => "check_type",
      "available" => "enabled",
      "message" => "last_error",
      "created_at" => "created_at"
    },
    "service_checks" => %{
      "timestamp" => "last_check_at",
      "service_name" => "name",
      "service_type" => "check_type",
      "available" => "enabled",
      "message" => "last_error",
      "created_at" => "created_at"
    },
    # Alerts - mostly direct mapping
    "alerts" => %{
      "timestamp" => "triggered_at",
      "created_at" => "triggered_at"
    },
    # Logs - SRQL uses syslog-style fields
    "logs" => %{
      "level" => "severity",
      "severity_id" => "severity",
      "timestamp" => "timestamp",
      "created_at" => "timestamp"
    },
    # OTel trace summaries - map common query fields
    "otel_trace_summaries" => %{
      "created_at" => "timestamp",
      "timestamp" => "timestamp"
    },
    # OTel traces - map common query fields
    "otel_traces" => %{
      "created_at" => "timestamp",
      "timestamp" => "timestamp"
    },
    # OTel metrics
    "otel_metrics" => %{
      "created_at" => "timestamp",
      "timestamp" => "timestamp"
    }
  }

  # Fields that should be ignored globally (don't exist in any Ash resources)
  @ignored_fields MapSet.new([
                    # otel_trace_summaries doesn't have stats
                    "stats",
                    # internal field
                    "raw_data",
                    # Ash internal
                    "__metadata__",
                    # TimescaleDB aggregation fields not in Ash resources
                    "series",
                    "agg",
                    "bucket"
                  ])

  # Fields that should be ignored for specific entities only
  @entity_ignored_fields %{
    # TimeseriesMetric doesn't have uid field
    "timeseries_metrics" => MapSet.new(["uid"]),
    "snmp_metrics" => MapSet.new(["uid"]),
    "rperf_metrics" => MapSet.new(["uid"]),
    # cpu_metrics uses device_id, not uid
    "cpu_metrics" => MapSet.new(["uid"]),
    "memory_metrics" => MapSet.new(["uid"]),
    "disk_metrics" => MapSet.new(["uid"]),
    "process_metrics" => MapSet.new(["uid"])
  }

  # Check if a field is an array type by introspecting the Ash resource
  # This is dynamic so we don't need to hardcode array field names
  defp array_field?(resource, field_name) when is_atom(field_name) do
    case Ash.Resource.Info.attribute(resource, field_name) do
      %{type: {:array, _}} -> true
      %{type: Ash.Type.Array} -> true
      _ -> false
    end
  rescue
    # If introspection fails, assume it's not an array
    _ -> false
  end

  defp array_field?(_resource, _field_name), do: false

  # Check if a field is a boolean type by introspecting the Ash resource
  defp boolean_field?(resource, field_name) when is_atom(field_name) do
    case Ash.Resource.Info.attribute(resource, field_name) do
      %{type: Ash.Type.Boolean} -> true
      %{type: :boolean} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp boolean_field?(_resource, _field_name), do: false

  # Parse a value as boolean
  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false
  defp parse_boolean("1"), do: true
  defp parse_boolean("0"), do: false
  defp parse_boolean(true), do: true
  defp parse_boolean(false), do: false
  defp parse_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      "yes" -> true
      "no" -> false
      "1" -> true
      "0" -> false
      _ -> nil
    end
  end
  defp parse_boolean(_), do: nil

  @doc """
  Check if an entity should be routed through Ash.
  """
  def ash_entity?(entity) when is_binary(entity), do: entity in @ash_entities
  def ash_entity?(_), do: false

  @doc """
  Execute a query through the Ash adapter.

  ## Parameters

  - `entity` - The entity name (e.g., "devices")
  - `params` - Query parameters map with:
    - `:filters` - List of filter conditions
    - `:sort` - Sort field and direction
    - `:limit` - Maximum results
    - `:cursor` - Pagination cursor
  - `scope` - The scope for policy enforcement (contains actor and context).
              Uses `Ash.Scope.ToOpts` protocol to extract actor.
              Schema is implicit from PostgreSQL search_path.

  ## Returns

  - `{:ok, response}` - Query succeeded
  - `{:error, reason}` - Query failed
  """
  def query(entity, params, scope \\ nil) do
    with {:ok, resource} <- get_resource(entity),
         {:ok, domain} <- get_domain(entity) do
      scope = normalize_scope(scope, resource)

      # Check if this is a stats query (aggregation)
      case Map.get(params, :stats) do
        stats when is_list(stats) and stats != [] ->
          with {:ok, query} <- build_query(resource, entity, params, apply_pagination?: false) do
            execute_stats_query(query, stats, scope, entity, params)
          end

        _ ->
          with {:ok, offset} <- decode_cursor(Map.get(params, :cursor)),
               {:ok, query} <-
                 build_query(resource, entity, Map.put(params, :offset, offset)) do
            case execute_query(domain, query, scope) do
              {:ok, results} -> {:ok, format_response(results, entity, params, offset)}
              {:error, reason} -> {:error, reason}
            end
          end
      end
    else
      {:error, reason} ->
        Logger.warning("SRQL AshAdapter query failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Execute a stats/aggregation query
  defp execute_stats_query(query, stats, scope_opts, entity, params) do
    opts = scope_opts_to_keyword_list(scope_opts)

    query =
      if scope_opts do
        Ash.Query.for_read(query, :read, %{}, opts)
      else
        query
      end

    # Build result map from stats
    result =
      Enum.reduce(stats, %{}, fn stat, acc ->
        case execute_single_stat(query, stat, opts) do
          {:ok, value} ->
            Map.put(acc, stat.alias, value)

          {:error, reason} ->
            Logger.debug("Stats query failed for #{stat.alias}: #{inspect(reason)}")
            Map.put(acc, stat.alias, 0)
        end
      end)

    {:ok, format_stats_response(result, entity, params)}
  end

  defp execute_single_stat(query, %{type: :count, alias: _alias}, opts) do
    case Ash.aggregate(query, {:count, :count}, opts) do
      {:ok, %{count: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_single_stat(query, %{type: :sum, field: field, alias: _alias}, opts) do
    field_atom = String.to_existing_atom(field)

    case Ash.aggregate(query, {:stat, :sum, field: field_atom}, opts) do
      {:ok, %{stat: sum}} -> {:ok, sum || 0}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:ok, 0}
  end

  defp execute_single_stat(query, %{type: :avg, field: field, alias: _alias}, opts) do
    field_atom = String.to_existing_atom(field)

    case Ash.aggregate(query, {:stat, :avg, field: field_atom}, opts) do
      {:ok, %{stat: avg}} -> {:ok, avg || 0}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:ok, 0}
  end

  defp execute_single_stat(query, %{type: :min, field: field, alias: _alias}, opts) do
    field_atom = String.to_existing_atom(field)

    case Ash.aggregate(query, {:stat, :min, field: field_atom}, opts) do
      {:ok, %{stat: min}} -> {:ok, min || 0}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:ok, 0}
  end

  defp execute_single_stat(query, %{type: :max, field: field, alias: _alias}, opts) do
    field_atom = String.to_existing_atom(field)

    case Ash.aggregate(query, {:stat, :max, field: field_atom}, opts) do
      {:ok, %{stat: max}} -> {:ok, max || 0}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:ok, 0}
  end

  defp execute_single_stat(_query, _stat, _opts), do: {:ok, 0}

  # Format stats response to match SRQL response format
  defp format_stats_response(result, _entity, params) do
    limit = Map.get(params, :limit, 100)

    %{
      "results" => [result],
      "pagination" => %{
        "next_cursor" => nil,
        "prev_cursor" => nil,
        "limit" => limit
      },
      "viz" => nil,
      "error" => nil
    }
  end

  @doc """
  Get the Ash resource for an entity.
  """
  def get_resource(entity) do
    case Map.get(@entity_resource_map, entity) do
      nil -> {:error, {:unknown_entity, entity}}
      resource -> {:ok, resource}
    end
  end

  @doc """
  Get the Ash domain for an entity.
  """
  def get_domain(entity) do
    case Map.get(@entity_domain_map, entity) do
      nil -> {:error, {:unknown_entity, entity}}
      domain -> {:ok, domain}
    end
  end

  # Build an Ash query from SRQL parameters
  defp build_query(resource, entity, params, opts \\ []) do
    apply_pagination? = Keyword.get(opts, :apply_pagination?, true)
    limit = Map.get(params, :limit)
    offset = Map.get(params, :offset)

    query =
      resource
      |> Ash.Query.new()
      |> apply_filters(resource, entity, Map.get(params, :filters, []))
      |> apply_sort(entity, Map.get(params, :sort))
      |> maybe_apply_offset(offset, apply_pagination?)
      |> maybe_apply_limit(limit, apply_pagination?)

    {:ok, query}
  rescue
    e ->
      {:error, {:query_build_error, Exception.message(e)}}
  end

  defp apply_filters(query, resource, entity, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_filter(q, resource, entity, filter)
    end)
  end

  defp apply_filters(query, _resource, _entity, _), do: query

  defp apply_filter(query, resource, entity, %{field: field, op: op, value: value}) do
    apply_filter_op(query, resource, entity, field, op, value)
  end

  defp apply_filter(query, resource, entity, %{"field" => field, "op" => op, "value" => value}) do
    apply_filter_op(query, resource, entity, field, op, value)
  end

  defp apply_filter(query, _resource, _entity, _), do: query

  defp apply_filter_op(query, resource, entity, field, op, value) when is_binary(field) do
    # Skip globally ignored fields
    if MapSet.member?(@ignored_fields, field) do
      query
    else
      # Skip entity-specific ignored fields
      entity_ignored = Map.get(@entity_ignored_fields, entity, MapSet.new())

      if MapSet.member?(entity_ignored, field) do
        query
      else
        # Map SRQL field name to Ash attribute name
        mapped_field = map_field(entity, field)
        field_atom = String.to_existing_atom(mapped_field)

        # Use Ash resource introspection to detect field types dynamically
        cond do
          boolean_field?(resource, field_atom) ->
            apply_boolean_filter(query, field_atom, op, value)

          array_field?(resource, field_atom) ->
            apply_array_filter(query, field_atom, op, value)

          true ->
            apply_scalar_filter(query, field_atom, op, value)
        end
      end
    end
  rescue
    # Field doesn't exist as atom, skip filter
    ArgumentError -> query
  end

  defp apply_filter_op(query, _, _, _, _, _), do: query

  # Handle boolean field filters - convert string values to actual booleans
  # This prevents errors like "boolean ~~ unknown" when LIKE is used on boolean fields
  defp apply_boolean_filter(query, field_atom, op, value) do
    bool_value = parse_boolean(value)

    case {op, bool_value} do
      # Standard equality operators
      {"eq", bool} when is_boolean(bool) ->
        Ash.Query.filter_input(query, %{field_atom => %{eq: bool}})

      {"neq", bool} when is_boolean(bool) ->
        Ash.Query.filter_input(query, %{field_atom => %{not_eq: bool}})

      # LIKE/contains on boolean should be treated as equality
      # e.g., is_available:"true" or is_available:%true% both mean is_available == true
      {op, bool} when op in ["like", "contains"] and is_boolean(bool) ->
        Ash.Query.filter_input(query, %{field_atom => %{eq: bool}})

      {op, bool} when op in ["not_like", "not_contains"] and is_boolean(bool) ->
        Ash.Query.filter_input(query, %{field_atom => %{not_eq: bool}})

      # IN operator with list of values
      {"in", _} when is_list(value) ->
        bool_values = Enum.map(value, &parse_boolean/1) |> Enum.filter(&is_boolean/1)
        if bool_values != [], do: Ash.Query.filter_input(query, %{field_atom => %{in: bool_values}}), else: query

      # If we can't parse the boolean value, skip the filter
      _ ->
        query
    end
  rescue
    _ -> query
  end

  # Handle array field filters using PostgreSQL array operators via fragments
  defp apply_array_filter(query, field_atom, op, value) do
    # Convert scalar to list
    values = if is_list(value), do: value, else: [value]

    case op do
      op when op in ["in", "eq", "contains", "like"] ->
        # Check if array contains any of the values using @> operator
        # PostgreSQL: array_field @> ARRAY['value'] checks containment
        Ash.Query.filter(query, expr(fragment("? @> ?::text[]", field(^field_atom), ^values)))

      op when op in ["not_in", "neq", "not_like"] ->
        # Negated - array doesn't contain all the values
        Ash.Query.filter(query, expr(not fragment("? @> ?::text[]", field(^field_atom), ^values)))

      _ ->
        query
    end
  rescue
    # Fall back to no filter on error
    _ -> query
  end

  # Handle scalar field filters
  defp apply_scalar_filter(query, field_atom, op, value) do
    # Use filter_input for dynamic filter building (recommended in Ash 3.x)
    case op do
      "eq" ->
        Ash.Query.filter_input(query, %{field_atom => %{eq: value}})

      "neq" ->
        Ash.Query.filter_input(query, %{field_atom => %{not_eq: value}})

      "gt" ->
        Ash.Query.filter_input(query, %{field_atom => %{greater_than: value}})

      "gte" ->
        Ash.Query.filter_input(query, %{field_atom => %{greater_than_or_equal: value}})

      "lt" ->
        Ash.Query.filter_input(query, %{field_atom => %{less_than: value}})

      "lte" ->
        Ash.Query.filter_input(query, %{field_atom => %{less_than_or_equal: value}})

      "contains" ->
        # String contains (substring match)
        Ash.Query.filter_input(query, %{field_atom => %{contains: value}})

      "like" ->
        # LIKE with wildcards - strip % and use substring contains
        pattern = value |> to_string() |> String.replace("%", "")
        Ash.Query.filter_input(query, %{field_atom => %{contains: pattern}})

      "not_like" ->
        # Negated LIKE - doesn't contain the pattern
        pattern = value |> to_string() |> String.replace("%", "")
        Ash.Query.filter_input(query, %{field_atom => %{not_contains: pattern}})

      "in" when is_list(value) ->
        Ash.Query.filter_input(query, %{field_atom => %{in: value}})

      "not_in" when is_list(value) ->
        Ash.Query.filter_input(query, %{field_atom => %{not_in: value}})

      _ ->
        query
    end
  rescue
    # Fall back to no filter on error
    _ -> query
  end

  defp apply_sort(query, _entity, nil), do: query

  defp apply_sort(query, entity, %{field: field, dir: dir}) do
    apply_sort_field(query, entity, field, dir)
  end

  defp apply_sort(query, entity, %{"field" => field, "dir" => dir}) do
    apply_sort_field(query, entity, field, dir)
  end

  defp apply_sort(query, _entity, _), do: query

  defp apply_sort_field(query, entity, field, dir) when is_binary(field) do
    # Skip globally ignored fields
    if MapSet.member?(@ignored_fields, field) do
      query
    else
      # Skip entity-specific ignored fields
      entity_ignored = Map.get(@entity_ignored_fields, entity, MapSet.new())

      if MapSet.member?(entity_ignored, field) do
        query
      else
        # Map SRQL field name to Ash attribute name
        mapped_field = map_field(entity, field)
        field_atom = String.to_existing_atom(mapped_field)

        direction =
          case dir do
            d when d in ["asc", :asc] -> :asc
            d when d in ["desc", :desc] -> :desc
            _ -> :desc
          end

        Ash.Query.sort(query, [{field_atom, direction}])
      end
    end
  rescue
    # Field doesn't exist as atom, skip sort
    ArgumentError -> query
  end

  defp apply_sort_field(query, _, _, _), do: query

  # Map SRQL field names to Ash attribute names
  defp map_field(entity, field) do
    case get_in(@field_mappings, [entity, field]) do
      # No mapping, use original
      nil -> field
      mapped -> mapped
    end
  end

  # Reverse map Ash attribute names to SRQL field names for response
  defp reverse_map_field(entity, field) do
    mappings = Map.get(@field_mappings, entity, %{})

    # Find reverse mapping
    case Enum.find(mappings, fn {_srql, ash} -> ash == field end) do
      {srql, _ash} -> srql
      # No mapping, use original
      nil -> field
    end
  end

  defp maybe_apply_limit(query, _limit, false), do: query
  defp maybe_apply_limit(query, limit, true), do: apply_limit(query, limit)

  defp apply_limit(query, nil), do: Ash.Query.limit(query, 100)

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0,
    do: Ash.Query.limit(query, limit)

  defp apply_limit(query, _), do: Ash.Query.limit(query, 100)

  defp maybe_apply_offset(query, _offset, false), do: query
  defp maybe_apply_offset(query, offset, true), do: apply_offset(query, offset)

  defp apply_offset(query, nil), do: query

  defp apply_offset(query, offset) when is_integer(offset) and offset > 0,
    do: Ash.Query.offset(query, offset)

  defp apply_offset(query, _), do: query

  # Execute the query against the Ash domain
  # Takes normalized scope map with :actor, :context, :authorize? keys
  defp execute_query(_domain, query, scope_opts) do
    opts = scope_opts_to_keyword_list(scope_opts)
    Ash.read(query, opts)
  end

  defp scope_opts_to_keyword_list(nil), do: []
  defp scope_opts_to_keyword_list(opts) when is_map(opts), do: Map.to_list(opts)
  defp scope_opts_to_keyword_list(_), do: []

  # Format the response to match SRQL response format
  defp format_response(results, entity, params, offset) do
    limit = Map.get(params, :limit, 100)
    {rows, _page} = normalize_page_results(results)

    %{
      "results" => Enum.map(rows, &format_result(&1, entity)),
      "pagination" => build_pagination(offset, limit, rows),
      "viz" => nil,
      "error" => nil
    }
  end

  # Ash internal fields that should never be exposed in SRQL responses
  @ash_internal_fields MapSet.new([
    :__meta__,
    :__metadata__,
    :__lateral_join_source__,
    :__order__,
    :aggregates,
    :calculations
  ])

  defp format_result(record, entity) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Map.reject(fn {k, _v} -> MapSet.member?(@ash_internal_fields, k) end)
    |> Enum.map(fn {k, v} ->
      field_name = Atom.to_string(k)
      # Optionally reverse map to SRQL field names for UI compatibility
      srql_name = reverse_map_field(entity, field_name)
      {srql_name, format_value(v)}
    end)
    |> Map.new()
    |> add_compatibility_fields(entity)
  end

  defp format_result(record, _entity), do: record

  # Add compatibility fields that SRQL/UI expects but Ash doesn't have
  defp add_compatibility_fields(row, "events") do
    time = Map.get(row, "event_timestamp") || Map.get(row, "timestamp") || Map.get(row, "time")
    event_type = Map.get(row, "event_type") || Map.get(row, "log_name")
    source = Map.get(row, "source") || get_in(row, ["actor", "app_name"])

    host =
      Map.get(row, "host") || get_in(row, ["device", "hostname"]) ||
        get_in(row, ["src_endpoint", "hostname"])

    row
    |> Map.put_new("event_timestamp", time)
    |> Map.put_new("timestamp", time)
    |> Map.put_new("event_type", event_type)
    |> Map.put_new("short_message", Map.get(row, "message"))
    |> Map.put_new("source", source)
    |> Map.put_new("host", host)
    |> Map.put_new("log_provider", Map.get(row, "source"))
    |> Map.put_new("log_name", event_type)
  end

  defp add_compatibility_fields(row, "services") do
    row
    |> Map.put_new("timestamp", Map.get(row, "last_check_at"))
    |> Map.put_new("service_name", Map.get(row, "name"))
    |> Map.put_new("service_type", Map.get(row, "check_type"))
    |> Map.put_new("available", Map.get(row, "enabled"))
  end

  defp add_compatibility_fields(row, "service_checks") do
    add_compatibility_fields(row, "services")
  end

  defp add_compatibility_fields(row, _entity), do: row

  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_value(%Date{} = d), do: Date.to_iso8601(d)
  defp format_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_value(%Ecto.Association.NotLoaded{}), do: nil
  # Skip unloaded associations
  defp format_value(value) when is_struct(value), do: nil
  defp format_value(value), do: value

  # Normalize scope to extract actor and authorization options.
  # Schema context is implicit from PostgreSQL search_path in single-deployment setups.
  defp normalize_scope(nil, _resource), do: nil

  defp normalize_scope(scope, _resource) do
    actor = extract_scope_value(Ash.Scope.ToOpts.get_actor(scope))
    context = extract_scope_value(Ash.Scope.ToOpts.get_context(scope))
    authorize? = extract_scope_value(Ash.Scope.ToOpts.get_authorize?(scope))

    %{}
    |> maybe_put(:actor, actor)
    |> maybe_put(:context, context)
    |> maybe_put(:authorize?, authorize?)
  end

  defp extract_scope_value({:ok, value}), do: value
  defp extract_scope_value(:error), do: nil
  defp extract_scope_value(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_page_results(%Ash.Page.Keyset{} = page), do: {page.results, page}
  defp normalize_page_results(%Ash.Page.Offset{} = page), do: {page.results, page}
  defp normalize_page_results(results) when is_list(results), do: {results, nil}
  defp normalize_page_results(_), do: {[], nil}

  defp build_pagination(offset, limit, results) do
    %{
      "next_cursor" => next_cursor(offset, limit, results),
      "prev_cursor" => prev_cursor(offset, limit),
      "limit" => limit
    }
  end

  defp next_cursor(offset, limit, results)
       when is_integer(offset) and is_integer(limit) and limit > 0 do
    if length(results) >= limit do
      encode_cursor(offset + limit)
    else
      nil
    end
  end

  defp next_cursor(_, _, _), do: nil

  defp prev_cursor(offset, limit)
       when is_integer(offset) and is_integer(limit) and limit > 0 and offset > 0 do
    encode_cursor(max(offset - limit, 0))
  end

  defp prev_cursor(_, _), do: nil

  defp decode_cursor(nil), do: {:ok, 0}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, payload} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"offset" => offset}} <- Jason.decode(payload),
         true <- is_integer(offset) do
      {:ok, max(offset, 0)}
    else
      _ -> {:error, "invalid cursor"}
    end
  end

  defp decode_cursor(_), do: {:error, "invalid cursor"}

  defp encode_cursor(offset) when is_integer(offset) do
    payload = Jason.encode!(%{offset: max(offset, 0)})
    Base.url_encode64(payload, padding: false)
  end
end
