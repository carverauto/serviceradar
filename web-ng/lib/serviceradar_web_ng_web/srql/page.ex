defmodule ServiceRadarWebNGWeb.SRQL.Page do
  @moduledoc false

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  def init(socket, entity, opts \\ []) when is_binary(entity) do
    default_limit = Keyword.get(opts, :default_limit, 100)
    builder_available = Keyword.get(opts, :builder_available, true)

    {builder_supported, builder_sync, builder, query} =
      if builder_available do
        builder = Builder.default_state(entity, default_limit)
        {true, true, builder, Builder.build(builder)}
      else
        {false, false, %{}, default_query(entity, default_limit)}
      end

    srql = %{
      enabled: true,
      entity: entity,
      page_path: nil,
      query: query,
      draft: query,
      error: nil,
      loading: false,
      builder_available: builder_available,
      builder_open: false,
      builder_supported: builder_supported,
      builder_sync: builder_sync,
      builder: builder
    }

    Phoenix.Component.assign(socket, :srql, srql)
  end

  def load_list(socket, params, uri, list_assign_key, opts \\ []) when is_atom(list_assign_key) do
    srql = Map.get(socket.assigns, :srql, %{})
    entity = srql_entity(srql, opts)
    builder_available = builder_available?(srql)

    default_limit = Keyword.get(opts, :default_limit, 20)
    max_limit = Keyword.get(opts, :max_limit, 100)
    limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)

    limit = parse_limit(Map.get(params, "limit"), default_limit, max_limit)
    cursor = normalize_optional_string(Map.get(params, "cursor"))

    builder = build_builder_state(params, srql, entity, limit, builder_available)
    default_query = default_query_for(builder_available, builder, entity, limit)
    query = normalize_query_param(Map.get(params, "q"), default_query)

    {builder_supported, builder_sync, builder_state} =
      parse_builder_state(builder_available, query, builder)

    srql_module = srql_module()
    actor = get_actor(socket)

    {results, error, viz_meta, pagination} =
      srql_results(srql_module, query, cursor, limit, actor)

    page_path = uri |> normalize_uri() |> URI.parse() |> Map.get(:path)

    display_limit =
      query
      |> extract_limit_from_srql(limit, default_limit, max_limit)

    srql =
      srql
      |> Map.merge(%{
        enabled: true,
        entity: entity,
        page_path: page_path,
        query: query,
        draft: query,
        error: error,
        viz: viz_meta,
        loading: false,
        builder_available: builder_available,
        builder_supported: builder_supported,
        builder_sync: builder_sync,
        builder: builder_state,
        pagination: pagination
      })

    socket
    |> Phoenix.Component.assign(:srql, srql)
    |> Phoenix.Component.assign(limit_assign_key, display_limit)
    |> Phoenix.Component.assign(list_assign_key, results)
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(_), do: nil

  def handle_event(socket, event, params, opts \\ [])

  def handle_event(socket, "srql_change", params, _opts) do
    case normalize_param_to_string(extract_param(params, "q")) do
      nil ->
        socket

      query ->
        srql = update_srql(socket, &Map.put(&1, :draft, query))
        Phoenix.Component.assign(socket, :srql, srql)
    end
  end

  def handle_event(socket, "srql_submit", params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    fallback_path = Keyword.get(opts, :fallback_path) || "/"
    extra_params = normalize_extra_params(Keyword.get(opts, :extra_params, %{}))

    raw_query = normalize_param_to_string(extract_param(params, "q")) || ""
    query = raw_query |> String.trim()
    query = if query == "", do: to_string(srql[:query] || ""), else: query

    limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)
    limit = Map.get(socket.assigns, limit_assign_key)

    # Extract entity from query and determine the target route
    target_path = entity_route_from_query(query, fallback_path)
    current_path = srql[:page_path] || fallback_path

    nav_params = Map.merge(extra_params, %{"q" => query, "limit" => limit})

    socket
    |> Phoenix.Component.assign(:srql, Map.put(srql, :builder_open, false))
    |> navigate_to_path(target_path, current_path, nav_params)
  end

  def handle_event(socket, "srql_builder_toggle", _params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})

    if builder_available?(srql) do
      toggle_builder(socket, srql, opts)
    else
      Phoenix.Component.assign(socket, :srql, Map.put(srql, :builder_open, false))
    end
  end

  def handle_event(socket, "srql_builder_change", params, _opts) do
    srql = Map.get(socket.assigns, :srql, %{})

    if builder_available?(srql) do
      builder_params =
        case extract_param(params, "builder") do
          %{} = v -> v
          _ -> %{}
        end

      builder = Builder.update(Map.get(srql, :builder, %{}), builder_params)

      updated = Map.put(srql, :builder, builder)

      updated =
        if updated[:builder_supported] and updated[:builder_sync] do
          Map.put(updated, :draft, Builder.build(builder))
        else
          updated
        end

      Phoenix.Component.assign(socket, :srql, updated)
    else
      Phoenix.Component.assign(socket, :srql, srql)
    end
  end

  def handle_event(socket, "srql_builder_add_filter", _params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})

    if builder_available?(srql) do
      entity = current_builder_entity(srql, opts)
      builder = Map.get(srql, :builder, Builder.default_state(entity))

      filters =
        builder
        |> Map.get("filters", [])
        |> List.wrap()

      next = %{
        "field" => default_filter_field(entity, filters),
        "op" => "contains",
        "value" => ""
      }

      updated_builder = Map.put(builder, "filters", filters ++ [next])

      updated =
        srql
        |> Map.put(:builder, updated_builder)
        |> maybe_sync_builder_to_draft()

      Phoenix.Component.assign(socket, :srql, updated)
    else
      Phoenix.Component.assign(socket, :srql, srql)
    end
  end

  def handle_event(socket, "srql_builder_remove_filter", params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})

    if builder_available?(srql) do
      entity = current_builder_entity(srql, opts)
      builder = Map.get(srql, :builder, Builder.default_state(entity))

      filters =
        builder
        |> Map.get("filters", [])
        |> List.wrap()

      idx = extract_param(params, "idx")
      raw_idx = normalize_param_to_string(idx) || ""

      index =
        case Integer.parse(raw_idx) do
          {i, ""} -> i
          _ -> -1
        end

      updated_filters =
        filters
        |> Enum.with_index()
        |> Enum.reject(fn {_f, i} -> i == index end)
        |> Enum.map(fn {f, _i} -> f end)

      updated_builder = Map.put(builder, "filters", updated_filters)

      updated =
        srql
        |> Map.put(:builder, updated_builder)
        |> maybe_sync_builder_to_draft()

      Phoenix.Component.assign(socket, :srql, updated)
    else
      Phoenix.Component.assign(socket, :srql, srql)
    end
  end

  def handle_event(socket, "srql_builder_apply", _params, _opts) do
    srql = Map.get(socket.assigns, :srql, %{})

    if builder_available?(srql) do
      builder = Map.get(srql, :builder, %{})
      query = Builder.build(builder)

      updated =
        srql
        |> Map.put(:builder_supported, true)
        |> Map.put(:builder_sync, true)
        |> Map.put(:draft, query)

      Phoenix.Component.assign(socket, :srql, updated)
    else
      Phoenix.Component.assign(socket, :srql, srql)
    end
  end

  def handle_event(socket, "srql_builder_run", _params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    fallback_path = Keyword.get(opts, :fallback_path) || "/"
    extra_params = normalize_extra_params(Keyword.get(opts, :extra_params, %{}))

    if builder_available?(srql) do
      # Build query from current builder state
      builder = Map.get(srql, :builder, %{})
      query = Builder.build(builder)

      limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)
      limit = Map.get(socket.assigns, limit_assign_key)

      # Extract entity from builder and determine the target route
      queried_entity = Map.get(builder, "entity", "devices")
      target_path = Catalog.entity(queried_entity)[:route] || fallback_path
      current_path = srql[:page_path] || fallback_path

      nav_params = Map.merge(extra_params, %{"q" => query, "limit" => limit})

      # Close builder and navigate with the new query
      socket
      |> Phoenix.Component.assign(:srql, Map.put(srql, :builder_open, false))
      |> navigate_to_path(target_path, current_path, nav_params)
    else
      socket
    end
  end

  def handle_event(socket, _event, _params, _opts), do: socket

  # Extracts entity from SRQL query and returns the appropriate route
  defp entity_route_from_query(query, fallback_path) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)in:(\S+)/, query) do
      [_, entity] ->
        Catalog.entity(entity)[:route] || fallback_path

      _ ->
        fallback_path
    end
  end

  defp entity_route_from_query(_query, fallback_path), do: fallback_path

  # Navigates to target path - uses push_patch if same path, push_navigate if different
  defp navigate_to_path(socket, target_path, current_path, params) do
    url = target_path <> "?" <> URI.encode_query(params)

    if target_path == current_path do
      Phoenix.LiveView.push_patch(socket, to: url)
    else
      Phoenix.LiveView.push_navigate(socket, to: url)
    end
  end

  defp normalize_extra_params(%{} = params) do
    params
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp normalize_extra_params(_), do: %{}

  defp srql_entity(srql, opts) do
    case Map.get(srql, :entity) || Keyword.get(opts, :entity) do
      value when is_binary(value) and value != "" -> value
      _ -> "devices"
    end
  end

  defp update_srql(socket, fun) do
    socket.assigns
    |> Map.get(:srql, %{})
    |> fun.()
  end

  defp extract_param(%{} = params, key) when is_binary(key) do
    case key do
      "q" -> Map.get(params, "q") || Map.get(params, :q)
      "builder" -> Map.get(params, "builder") || Map.get(params, :builder)
      "idx" -> Map.get(params, "idx") || Map.get(params, :idx)
      _ -> Map.get(params, key)
    end
  end

  defp extract_param(_params, _key), do: nil

  defp normalize_param_to_string(nil), do: nil
  defp normalize_param_to_string(value) when is_binary(value), do: value

  defp normalize_param_to_string([first | _]) when is_binary(first), do: first

  defp normalize_param_to_string(value) when is_list(value) do
    if Enum.all?(value, &is_integer/1) do
      to_string(value)
    else
      inspect(value)
    end
  end

  defp normalize_param_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_param_to_string(value) when is_float(value), do: :erlang.float_to_binary(value)
  defp normalize_param_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_param_to_string(value) when is_map(value), do: inspect(value)
  defp normalize_param_to_string(value), do: inspect(value)

  defp get_actor(socket) do
    case socket.assigns do
      %{current_scope: %{user: user}} when not is_nil(user) -> user
      _ -> nil
    end
  end

  defp normalize_query_param(value, default_query) do
    case normalize_param_to_string(value) do
      nil ->
        default_query

      query ->
        query
        |> String.trim()
        |> case do
          "" -> default_query
          other -> String.slice(other, 0, 4000)
        end
    end
  end

  defp builder_available?(srql), do: Map.get(srql, :builder_available, false)

  defp build_builder_state(params, srql, entity, limit, true) do
    base =
      if Map.has_key?(params, "q") do
        Map.get(srql, :builder, Builder.default_state(entity, limit))
      else
        Builder.default_state(entity, limit)
      end

    base
    |> Map.put("entity", entity)
    |> Map.put("limit", limit)
  end

  defp build_builder_state(_params, _srql, _entity, _limit, false), do: %{}

  defp default_query_for(true, builder, _entity, _limit), do: Builder.build(builder)
  defp default_query_for(false, _builder, entity, limit), do: default_query(entity, limit)

  defp parse_builder_state(true, query, builder) do
    case Builder.parse(query) do
      {:ok, parsed} -> {true, true, parsed}
      {:error, _} -> {false, false, builder}
    end
  end

  defp parse_builder_state(false, _query, _builder), do: {false, false, %{}}

  defp srql_results(srql_module, query, cursor, limit, actor) do
    case srql_module.query(query, %{cursor: cursor, limit: limit, actor: actor}) do
      {:ok, %{"results" => results, "pagination" => pag} = resp} when is_list(results) ->
        {results, nil, extract_viz(resp), pag || %{}}

      {:ok, %{"results" => results} = resp} when is_list(results) ->
        {results, nil, extract_viz(resp), %{}}

      {:ok, other} ->
        {[], "unexpected SRQL response: #{inspect(other)}", nil, %{}}

      {:error, reason} ->
        {[], "SRQL error: #{format_error(reason)}", nil, %{}}
    end
  end

  defp extract_viz(resp) do
    case Map.get(resp, "viz") do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp toggle_builder(socket, srql, opts) do
    if Map.get(srql, :builder_open, false) do
      Phoenix.Component.assign(socket, :srql, Map.put(srql, :builder_open, false))
    else
      entity = srql_entity(srql, opts)
      limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)
      limit = Map.get(socket.assigns, limit_assign_key, 100)

      current = srql[:draft] || srql[:query] || ""
      current = normalize_param_to_string(current) || ""

      {supported, sync, builder} = parse_builder_for_toggle(current, entity, limit)

      updated =
        srql
        |> Map.put(:builder_open, true)
        |> Map.put(:builder_supported, supported)
        |> Map.put(:builder_sync, sync)
        |> Map.put(:builder, builder)

      Phoenix.Component.assign(socket, :srql, updated)
    end
  end

  defp parse_builder_for_toggle(current, entity, limit) do
    case Builder.parse(current) do
      {:ok, builder} -> {true, true, builder}
      {:error, _} -> {false, false, Builder.default_state(entity, limit)}
    end
  end

  defp normalize_uri(uri) when is_binary(uri), do: uri
  defp normalize_uri(%URI{} = uri), do: URI.to_string(uri)
  defp normalize_uri(nil), do: ""
  defp normalize_uri(other), do: inspect(other)

  defp maybe_sync_builder_to_draft(srql) do
    if srql[:builder_supported] and srql[:builder_sync] do
      Map.put(srql, :draft, Builder.build(srql[:builder] || %{}))
    else
      srql
    end
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default, max)
      _ -> default
    end
  end

  defp parse_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    min(limit, max)
  end

  defp parse_limit(_limit, default, _max), do: default

  defp extract_limit_from_srql(query, fallback, default, max) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)limit:(\d+)(?:\s|$)/, query) do
      [_, raw] -> parse_limit(raw, default, max)
      _ -> fallback
    end
  end

  defp extract_limit_from_srql(_query, fallback, _default, _max), do: fallback

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp default_filter_field(entity, _filters) do
    Catalog.entity(entity).default_filter_field
  end

  defp current_builder_entity(srql, opts) do
    candidate =
      srql
      |> Map.get(:builder, %{})
      |> Map.get("entity")
      |> normalize_param_to_string()
      |> case do
        nil -> ""
        value -> value
      end
      |> String.trim()

    if candidate != "" do
      candidate
    else
      srql_entity(srql, opts)
    end
  end

  defp default_query(entity, limit) do
    limit = parse_limit(limit, 100, 500)

    tokens =
      ["in:#{entity}"]
      |> maybe_add_default_time(entity)
      |> Kernel.++(["limit:#{limit}"])

    Enum.join(tokens, " ")
  end

  defp maybe_add_default_time(tokens, entity) do
    if entity in [
         "events",
         "logs",
         "device_updates",
         "otel_metrics",
         "timeseries_metrics",
         "snmp_metrics",
         "rperf_metrics",
         "cpu_metrics",
         "memory_metrics",
         "disk_metrics",
         "process_metrics"
       ] do
      tokens ++ ["time:last_7d"]
    else
      tokens
    end
  end
end
