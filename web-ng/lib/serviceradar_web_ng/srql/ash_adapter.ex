defmodule ServiceRadarWebNG.SRQL.AshAdapter do
  @moduledoc """
  Adapter for routing SRQL queries to Ash resources.

  This adapter intercepts SRQL queries for certain entities and routes them
  through Ash resources instead of the SQL path. This provides:

  - Policy enforcement via Ash.Policy.Authorizer
  - Multi-tenancy support
  - Consistent authorization across web and API

  ## Supported Entities

  The following entities are routed through Ash:
  - `devices` -> ServiceRadar.Inventory.Device
  - `pollers` -> ServiceRadar.Infrastructure.Poller
  - `agents` -> ServiceRadar.Infrastructure.Agent

  ## SQL Path Entities

  The following entities remain on the SQL path for performance:
  - All metrics (timeseries_metrics, snmp_metrics, cpu_metrics, etc.)
  - Flows, traces
  - Events, logs (until Event resource is fully integrated)

  ## Usage

  The adapter is called by the SRQL module when the feature flag is enabled:

      # In config/config.exs
      config :serviceradar_web_ng, :feature_flags,
        ash_srql_adapter: true

  Queries include the actor for policy enforcement:

      AshAdapter.query("devices", %{filters: [...], sort: [...], limit: 100}, actor)
  """

  require Logger

  # Entities that should be routed through Ash
  @ash_entities ~w(devices pollers agents)

  # Entity to Ash resource mapping
  @entity_resource_map %{
    "devices" => ServiceRadar.Inventory.Device,
    "pollers" => ServiceRadar.Infrastructure.Poller,
    "agents" => ServiceRadar.Infrastructure.Agent
  }

  # Entity to domain mapping
  @entity_domain_map %{
    "devices" => ServiceRadar.Inventory,
    "pollers" => ServiceRadar.Infrastructure,
    "agents" => ServiceRadar.Infrastructure
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
         {:ok, query} <- build_query(resource, params),
         {:ok, results} <- execute_query(domain, query, actor) do
      {:ok, format_response(results, params)}
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
  defp build_query(resource, params) do
    query = Ash.Query.new(resource)

    query =
      query
      |> apply_filters(Map.get(params, :filters, []))
      |> apply_sort(Map.get(params, :sort))
      |> apply_limit(Map.get(params, :limit))

    {:ok, query}
  rescue
    e ->
      {:error, {:query_build_error, Exception.message(e)}}
  end

  defp apply_filters(query, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_filter(q, filter)
    end)
  end

  defp apply_filters(query, _), do: query

  defp apply_filter(query, %{field: field, op: op, value: value}) do
    apply_filter_op(query, field, op, value)
  end

  defp apply_filter(query, %{"field" => field, "op" => op, "value" => value}) do
    apply_filter_op(query, field, op, value)
  end

  defp apply_filter(query, _), do: query

  defp apply_filter_op(query, field, op, value) when is_binary(field) do
    field_atom = String.to_existing_atom(field)

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
    ArgumentError -> query  # Field doesn't exist as atom, skip filter
  end

  defp apply_filter_op(query, _, _, _), do: query

  defp apply_sort(query, nil), do: query

  defp apply_sort(query, %{field: field, dir: dir}) do
    apply_sort_field(query, field, dir)
  end

  defp apply_sort(query, %{"field" => field, "dir" => dir}) do
    apply_sort_field(query, field, dir)
  end

  defp apply_sort(query, _), do: query

  defp apply_sort_field(query, field, dir) when is_binary(field) do
    field_atom = String.to_existing_atom(field)

    direction =
      case dir do
        d when d in ["asc", :asc] -> :asc
        d when d in ["desc", :desc] -> :desc
        _ -> :desc
      end

    Ash.Query.sort(query, [{field_atom, direction}])
  rescue
    ArgumentError -> query  # Field doesn't exist as atom, skip sort
  end

  defp apply_sort_field(query, _, _), do: query

  defp apply_limit(query, nil), do: Ash.Query.limit(query, 100)
  defp apply_limit(query, limit) when is_integer(limit) and limit > 0, do: Ash.Query.limit(query, limit)
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
  defp format_response(results, params) when is_list(results) do
    limit = Map.get(params, :limit, 100)

    %{
      "results" => Enum.map(results, &format_result/1),
      "pagination" => %{
        "next_cursor" => nil,  # TODO: Implement keyset pagination
        "prev_cursor" => nil,
        "limit" => limit
      },
      "viz" => nil,
      "error" => nil
    }
  end

  defp format_result(record) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__])
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), format_value(v)} end)
    |> Map.new()
  end

  defp format_result(record), do: record

  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_value(%Date{} = d), do: Date.to_iso8601(d)
  defp format_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_value(%Ecto.Association.NotLoaded{}), do: nil
  defp format_value(value) when is_struct(value), do: nil  # Skip unloaded associations
  defp format_value(value), do: value
end
