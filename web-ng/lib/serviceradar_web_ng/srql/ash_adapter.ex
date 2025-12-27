defmodule ServiceRadarWebNG.SRQL.AshAdapter do
  @moduledoc """
  Adapter for routing SRQL queries to Ash resources.

  This adapter intercepts SRQL queries for certain entities and routes them
  through Ash resources instead of the SQL path. This provides:

  - Policy enforcement via Ash.Policy.Authorizer
  - Multi-tenancy support
  - Consistent authorization across web and API

  ## Supported Entities

  All SRQL entities are now routed through Ash:

  ### Inventory Domain
  - `devices` -> ServiceRadar.Inventory.Device

  ### Infrastructure Domain
  - `pollers` -> ServiceRadar.Infrastructure.Poller
  - `agents` -> ServiceRadar.Infrastructure.Agent

  ### Monitoring Domain
  - `events` -> ServiceRadar.Monitoring.Event
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

  # ALL entities are routed through Ash - no exceptions
  @ash_entities ~w(
    devices pollers agents events alerts services service_checks
    logs timeseries_metrics cpu_metrics memory_metrics disk_metrics
    snmp_metrics rperf_metrics process_metrics
    otel_metrics otel_traces otel_trace_summaries
  )

  # Entity to Ash resource mapping
  @entity_resource_map %{
    # Inventory domain
    "devices" => ServiceRadar.Inventory.Device,
    # Infrastructure domain
    "pollers" => ServiceRadar.Infrastructure.Poller,
    "agents" => ServiceRadar.Infrastructure.Agent,
    # Monitoring domain
    "events" => ServiceRadar.Monitoring.Event,
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
    "pollers" => ServiceRadar.Infrastructure,
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
      "modified" => "modified_time"
    },
    # Events: SRQL uses CloudEvents schema, Ash uses different names
    "events" => %{
      "event_timestamp" => "occurred_at",
      "timestamp" => "occurred_at",
      "type" => "event_type",
      "source" => "source_id",
      "severity" => "severity",
      "short_message" => "message",
      "level" => "severity",
      "id" => "id"
    },
    # ServiceChecks (services): Map SRQL service_status to service_checks
    "services" => %{
      "timestamp" => "last_check_at",
      "service_name" => "name",
      "service_type" => "check_type",
      "available" => "enabled",
      "message" => "last_error"
    },
    "service_checks" => %{
      "timestamp" => "last_check_at",
      "service_name" => "name",
      "service_type" => "check_type",
      "available" => "enabled",
      "message" => "last_error"
    },
    # Alerts - mostly direct mapping
    "alerts" => %{
      "timestamp" => "triggered_at"
    },
    # Logs - SRQL uses syslog-style fields
    "logs" => %{
      "level" => "severity",
      "severity_id" => "severity"
    }
  }

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
  - `actor` - The actor for policy enforcement (usually a User)

  ## Returns

  - `{:ok, response}` - Query succeeded
  - `{:error, reason}` - Query failed
  """
  def query(entity, params, actor \\ nil) do
    with {:ok, resource} <- get_resource(entity),
         {:ok, domain} <- get_domain(entity),
         {:ok, query} <- build_query(resource, entity, params),
         {:ok, results} <- execute_query(domain, query, actor) do
      {:ok, format_response(results, entity, params)}
    else
      {:error, reason} ->
        Logger.warning("SRQL AshAdapter query failed: #{inspect(reason)}")
        {:error, reason}
    end
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
  defp build_query(resource, entity, params) do
    query = Ash.Query.new(resource)

    query =
      query
      |> apply_filters(entity, Map.get(params, :filters, []))
      |> apply_sort(entity, Map.get(params, :sort))
      |> apply_limit(Map.get(params, :limit))

    {:ok, query}
  rescue
    e ->
      {:error, {:query_build_error, Exception.message(e)}}
  end

  defp apply_filters(query, entity, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_filter(q, entity, filter)
    end)
  end

  defp apply_filters(query, _entity, _), do: query

  defp apply_filter(query, entity, %{field: field, op: op, value: value}) do
    apply_filter_op(query, entity, field, op, value)
  end

  defp apply_filter(query, entity, %{"field" => field, "op" => op, "value" => value}) do
    apply_filter_op(query, entity, field, op, value)
  end

  defp apply_filter(query, _entity, _), do: query

  defp apply_filter_op(query, entity, field, op, value) when is_binary(field) do
    # Map SRQL field name to Ash attribute name
    mapped_field = map_field(entity, field)
    field_atom = String.to_existing_atom(mapped_field)

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
        Ash.Query.filter_input(query, %{field_atom => %{contains: value}})

      "in" when is_list(value) ->
        Ash.Query.filter_input(query, %{field_atom => %{in: value}})

      _ ->
        query
    end
  rescue
    # Field doesn't exist as atom, skip filter
    ArgumentError -> query
  end

  defp apply_filter_op(query, _, _, _, _), do: query

  defp apply_sort(query, _entity, nil), do: query

  defp apply_sort(query, entity, %{field: field, dir: dir}) do
    apply_sort_field(query, entity, field, dir)
  end

  defp apply_sort(query, entity, %{"field" => field, "dir" => dir}) do
    apply_sort_field(query, entity, field, dir)
  end

  defp apply_sort(query, _entity, _), do: query

  defp apply_sort_field(query, entity, field, dir) when is_binary(field) do
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

  defp apply_limit(query, nil), do: Ash.Query.limit(query, 100)

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0,
    do: Ash.Query.limit(query, limit)

  defp apply_limit(query, _), do: Ash.Query.limit(query, 100)

  # Execute the query against the Ash domain
  # Note: domain is passed for future use with explicit domain routing
  defp execute_query(_domain, query, actor) do
    opts =
      if actor do
        [actor: actor]
      else
        []
      end

    Ash.read(query, opts)
  end

  # Format the response to match SRQL response format
  defp format_response(results, entity, params) when is_list(results) do
    limit = Map.get(params, :limit, 100)

    %{
      "results" => Enum.map(results, &format_result(&1, entity)),
      "pagination" => %{
        # TODO: Implement keyset pagination
        "next_cursor" => nil,
        "prev_cursor" => nil,
        "limit" => limit
      },
      "viz" => nil,
      "error" => nil
    }
  end

  defp format_result(record, entity) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__])
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
    row
    |> Map.put_new("event_timestamp", Map.get(row, "occurred_at"))
    |> Map.put_new("timestamp", Map.get(row, "occurred_at"))
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
end
