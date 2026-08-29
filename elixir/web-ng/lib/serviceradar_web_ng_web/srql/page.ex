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
      builder: builder,
      builder_mode_notice: nil,
      default_limit: default_limit
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

    # Cursor may arrive from legacy URLs or from session-position paginate/3.
    # New navigation never writes cursor into the shareable address bar.
    cursor = normalize_optional_string(Map.get(params, "cursor"))
    pagination_page = resolve_pagination_page(params, socket, cursor)

    # Limit resolution: SRQL limit:N (preferred) → URL limit= (legacy) → default.
    # Avoid double-encoding the same value in both places when writing URLs.
    provisional_limit = resolve_limit(nil, Map.get(params, "limit"), default_limit, max_limit)
    builder = build_builder_state(params, srql, entity, provisional_limit, builder_available)
    default_query = default_query_for(builder_available, builder, entity, provisional_limit)

    query =
      params
      |> Map.get("q")
      |> normalize_query_param(default_query)
      |> ensure_default_time_window(entity)

    limit = resolve_limit(query, Map.get(params, "limit"), default_limit, max_limit)

    {builder_supported, builder_sync, builder_state} =
      parse_builder_state(builder_available, query, builder)

    srql_module = srql_module()
    scope = get_scope(socket)

    {results, error, viz_meta, pagination} =
      srql_results(srql_module, query, cursor, limit, scope)

    page_path = uri |> normalize_uri() |> URI.parse() |> Map.get(:path)

    display_limit = limit

    srql =
      Map.merge(srql, %{
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
        builder_mode_notice: nil,
        pagination: pagination,
        # Session-position pagination context for srql_paginate events.
        list_assign_key: list_assign_key,
        load_opts: %{default_limit: default_limit, max_limit: max_limit, limit_assign_key: limit_assign_key}
      })

    socket
    |> Phoenix.Component.assign(:srql, srql)
    |> Phoenix.Component.assign(limit_assign_key, display_limit)
    |> Phoenix.Component.assign(list_assign_key, results)
    |> Phoenix.Component.assign(:pagination_page, pagination_page)
  end

  @doc """
  Advance keyset pagination without encoding cursor/page into the URL.

  Position lives in LiveView assigns (`pagination_page`, SRQL pagination tokens).
  Shareable intent stays as tab + q only.
  """
  def paginate(socket, event_params, opts \\ []) when is_map(event_params) do
    srql = Map.get(socket.assigns, :srql, %{})
    load_opts = Map.get(srql, :load_opts, %{})

    list_assign_key =
      Keyword.get(opts, :list_assign_key) ||
        Map.get(srql, :list_assign_key) ||
        raise ArgumentError, "paginate/3 requires list_assign_key (pass opts or load_list first)"

    default_limit =
      Keyword.get(opts, :default_limit) || Map.get(load_opts, :default_limit, 20)

    max_limit = Keyword.get(opts, :max_limit) || Map.get(load_opts, :max_limit, 100)

    limit_assign_key =
      Keyword.get(opts, :limit_assign_key) || Map.get(load_opts, :limit_assign_key, :limit)

    cursor = normalize_optional_string(Map.get(event_params, "cursor"))
    page = parse_pagination_page(Map.get(event_params, "page"), 1)

    query = Map.get(srql, :query, "")
    page_path = Map.get(srql, :page_path) || Keyword.get(opts, :fallback_path, "/")

    params =
      then(%{"q" => query, "page" => Integer.to_string(page)}, fn p ->
        if cursor, do: Map.put(p, "cursor", cursor), else: p
      end)

    load_list(socket, params, page_path, list_assign_key,
      default_limit: default_limit,
      max_limit: max_limit,
      limit_assign_key: limit_assign_key
    )
  end

  def sync_from_params(socket, params, uri, opts \\ []) do
    srql = Map.get(socket.assigns, :srql, %{})
    entity = srql_entity(srql, opts)
    builder_available = builder_available?(srql)

    default_limit = Keyword.get(opts, :default_limit, 20)
    max_limit = Keyword.get(opts, :max_limit, 100)
    limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)

    provisional_limit = resolve_limit(nil, Map.get(params, "limit"), default_limit, max_limit)
    builder = build_builder_state(params, srql, entity, provisional_limit, builder_available)
    default_query = default_query_for(builder_available, builder, entity, provisional_limit)

    query =
      params
      |> Map.get("q")
      |> normalize_query_param(default_query)
      |> ensure_default_time_window(entity)

    display_limit = resolve_limit(query, Map.get(params, "limit"), default_limit, max_limit)

    {builder_supported, builder_sync, builder_state} =
      parse_builder_state(builder_available, query, builder)

    page_path = uri |> normalize_uri() |> URI.parse() |> Map.get(:path)

    srql =
      Map.merge(srql, %{
        enabled: true,
        entity: entity,
        page_path: page_path,
        query: query,
        draft: query,
        error: nil,
        loading: true,
        builder_available: builder_available,
        builder_supported: builder_supported,
        builder_sync: builder_sync,
        builder: builder_state,
        builder_mode_notice: nil
      })

    socket
    |> Phoenix.Component.assign(:srql, srql)
    |> Phoenix.Component.assign(limit_assign_key, display_limit)
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(_), do: nil

  def handle_event(socket, event, params, opts \\ [])

  def handle_event(socket, "srql_paginate", params, opts) when is_map(params) do
    paginate(socket, params, opts)
  end

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
    query = String.trim(raw_query)
    query = if query == "", do: to_string(srql[:query] || ""), else: query

    query =
      query
      |> shortcut_query()
      |> sanitize_query()

    # Extract entity from query and determine the target route
    {target_path, route_params} = route_target_for_query(query, fallback_path)
    current_path = srql[:page_path] || fallback_path

    # Shareable URL = intent only (tab + q). Limit lives in SRQL (limit:N);
    # cursor/page stay out of navigation patches.
    nav_params = navigation_params(extra_params, route_params, target_path, current_path, query)

    socket
    |> Phoenix.Component.assign(:srql, Map.put(srql, :builder_open, false))
    |> navigate_to_path(target_path, current_path, nav_params)
  end

  def handle_event(socket, "srql_reset", _params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    fallback_path = Keyword.get(opts, :fallback_path) || "/"

    extra_params =
      opts
      |> Keyword.get(:extra_params, %{})
      |> normalize_extra_params()
      |> Map.drop(["q", "cursor", "page", "nf"])

    query = reset_query(srql, opts)
    current_path = srql[:page_path] || fallback_path

    nav_params = navigation_params(extra_params, %{}, current_path, current_path, query)

    socket
    |> Phoenix.Component.assign(:srql, Map.put(srql, :builder_open, false))
    |> navigate_to_path(current_path, current_path, nav_params)
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

      {builder, stripped} =
        Builder.update_meta(Map.get(srql, :builder, %{}), builder_params)

      updated =
        srql
        |> Map.put(:builder, builder)
        |> Map.put(:builder_mode_notice, mode_strip_notice(stripped, Builder.mode(builder)))

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

      field = default_filter_field(entity, builder)
      config = Catalog.entity(entity)
      boolean_fields = Map.get(config, :boolean_fields, [])

      # Use appropriate defaults based on field type. `default_filter_op/2` keeps
      # the seeded operator in step with the operator list the UI offers for the
      # field -- notably `equals` for addresses, where `contains` would substring
      # match (10.0.0.1 also matching 110.0.0.1).
      default_op = Catalog.default_filter_op(config, field)
      default_value = if field in boolean_fields, do: "true", else: ""

      next = %{
        "field" => field,
        "op" => default_op,
        "value" => default_value
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
      query = builder |> Builder.build() |> sanitize_query()

      # Extract entity from builder and determine the target route
      queried_entity = Map.get(builder, "entity", "devices")
      {target_path, route_params} = route_target_for_entity(queried_entity, fallback_path)
      current_path = srql[:page_path] || fallback_path

      nav_params = navigation_params(extra_params, route_params, target_path, current_path, query)

      # Close builder and navigate with the new query
      socket
      |> Phoenix.Component.assign(:srql, Map.put(srql, :builder_open, false))
      |> navigate_to_path(target_path, current_path, nav_params)
    else
      socket
    end
  end

  def handle_event(socket, _event, _params, _opts), do: socket

  def shortcut_query(query) do
    cond do
      not bare_device_search?(query) ->
        query

      ipv4_address?(query) ->
        ~s(in:devices ip:"#{escape_shortcut_value(query)}")

      hostname?(query) ->
        ~s(in:devices hostname:"#{escape_shortcut_value(query)}")

      true ->
        query
    end
  end

  defp bare_device_search?(query) when is_binary(query) do
    query != "" and not String.contains?(query, [":", " ", "\t", "\n", "\r"])
  end

  defp bare_device_search?(_query), do: false

  defp ipv4_address?(query) do
    case :inet.parse_address(to_charlist(query)) do
      {:ok, {a, b, c, d}} when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
        true

      _ ->
        false
    end
  end

  defp hostname?(query) do
    String.match?(query, ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$/)
  end

  defp escape_shortcut_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  def route_for_query(query, fallback_path) when is_binary(query) do
    {path, _params} = route_target_for_query(query, fallback_path)
    path
  end

  def route_for_query(_query, fallback_path), do: fallback_path

  def route_target_for_query(query, fallback_path) when is_binary(query) do
    query
    |> entity_from_query()
    |> route_target_for_entity(fallback_path)
  end

  def route_target_for_query(_query, fallback_path), do: {fallback_path, %{}}

  def route_target_for_entity(entity, fallback_path) when is_binary(entity) do
    config = Catalog.entity(entity)
    route = Map.get(config, :route)

    # Blank routes must fall back — empty string is truthy in Elixir and would
    # make push_navigate receive only a query string ("?q=...").
    path =
      if is_binary(route) and String.trim(route) != "" do
        route
      else
        fallback_path
      end

    {
      path,
      config |> Map.get(:route_params, %{}) |> normalize_extra_params()
    }
  end

  def route_target_for_entity(_entity, fallback_path), do: {fallback_path, %{}}

  def sanitize_query(query) when is_binary(query) do
    tokens = tokenize_query(query)
    entity = entity_from_tokens(tokens)

    tokens
    |> Enum.reject(&invalid_entity_filter_token?(&1, entity))
    |> Enum.join(" ")
  end

  def sanitize_query(query), do: query

  # Navigates to target path - uses push_patch if same path, push_navigate if different
  defp navigate_to_path(socket, target_path, current_path, params) do
    url = target_path <> "?" <> URI.encode_query(params)

    if target_path == current_path do
      Phoenix.LiveView.push_patch(socket, to: url)
    else
      Phoenix.LiveView.push_navigate(socket, to: url)
    end
  end

  # Intent-only shareable params: q + scoped extras (e.g. tab). No limit/cursor/page.
  defp navigation_params(extra_params, route_params, target_path, current_path, query) do
    extra_params
    |> scoped_extra_params(route_params, target_path, current_path)
    |> Map.merge(route_params)
    |> Map.put("q", query)
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp scoped_extra_params(extra_params, route_params, target_path, current_path) do
    route_tab = Map.get(route_params, "tab")
    extra_tab = Map.get(extra_params, "tab")

    cond do
      target_path != current_path -> %{}
      is_binary(route_tab) and extra_tab not in [nil, route_tab] -> %{}
      true -> extra_params
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

  defp tokenize_query(query) when is_binary(query) do
    {tokens_rev, current, _in_quotes, _escaped} =
      query
      |> String.trim()
      |> String.graphemes()
      |> Enum.reduce({[], "", false, false}, fn ch, {tokens_rev, current, in_quotes, escaped} ->
        cond do
          escaped ->
            {tokens_rev, current <> ch, in_quotes, false}

          ch == "\\" ->
            {tokens_rev, current <> ch, in_quotes, true}

          ch == "\"" ->
            {tokens_rev, current <> ch, not in_quotes, false}

          String.match?(ch, ~r/\s/) and not in_quotes ->
            push_query_token(tokens_rev, current, in_quotes)

          true ->
            {tokens_rev, current <> ch, in_quotes, false}
        end
      end)

    tokens_rev
    |> finalize_query_tokens(current)
    |> Enum.reverse()
  end

  defp push_query_token(tokens_rev, "", in_quotes), do: {tokens_rev, "", in_quotes, false}
  defp push_query_token(tokens_rev, current, in_quotes), do: {[current | tokens_rev], "", in_quotes, false}
  defp finalize_query_tokens(tokens_rev, ""), do: tokens_rev
  defp finalize_query_tokens(tokens_rev, current), do: [current | tokens_rev]

  defp entity_from_tokens(tokens) when is_list(tokens) do
    Enum.find_value(tokens, "devices", fn
      "in:" <> entity when entity != "" -> entity
      _ -> nil
    end)
  end

  defp entity_from_query(query) when is_binary(query) do
    Enum.find_value(tokenize_query(query), fn
      "in:" <> entity when entity != "" -> entity
      _ -> nil
    end)
  end

  @srql_control_fields ~w(in limit sort time bucket agg value_field series stats group by)

  defp invalid_entity_filter_token?(token, entity) when is_binary(token) do
    case token_field(token) do
      nil ->
        false

      field ->
        field not in @srql_control_fields and field in known_catalog_filter_fields() and
          field not in allowed_entity_filter_fields(entity)
    end
  end

  defp invalid_entity_filter_token?(_token, _entity), do: false

  defp token_field("!" <> token), do: token_field(token)

  defp token_field(token) when is_binary(token) do
    case String.split(token, ":", parts: 2) do
      [field, _value] when field != "" -> field
      _ -> nil
    end
  end

  defp allowed_entity_filter_fields(entity) do
    config = Catalog.entity(entity)

    config
    |> catalog_filter_fields()
    |> Enum.uniq()
  end

  defp known_catalog_filter_fields do
    Catalog.entities()
    |> Enum.flat_map(&catalog_filter_fields/1)
    |> Enum.uniq()
  end

  defp catalog_filter_fields(config) when is_map(config) do
    [
      Map.get(config, :filter_fields, []),
      Map.get(config, :filter_fields_downsample, []),
      Map.get(config, :boolean_fields, []),
      Map.get(config, :array_fields, []),
      Map.get(config, :numeric_fields, []),
      Map.get(config, :series_fields, []),
      Map.get(config, :stats_fields, []),
      Map.get(config, :value_fields, [])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp mode_strip_notice([], _mode), do: nil
  defp mode_strip_notice(nil, _mode), do: nil

  defp mode_strip_notice(fields, mode) when is_list(fields) do
    names = fields |> Enum.uniq() |> Enum.join(", ")

    count = length(fields)

    noun = if count == 1, do: "filter", else: "filters"
    context = if mode == :downsample, do: "chart mode", else: "the current query mode"

    "Removed #{count} #{noun} not available in #{context}: #{names}"
  end

  defp get_scope(socket) do
    Map.get(socket.assigns, :current_scope)
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

  defp ensure_default_time_window(query, "logs") when is_binary(query) do
    tokens = tokenize_query(query)

    if entity_from_tokens(tokens) == "logs" and not Enum.any?(tokens, &String.starts_with?(&1, "time:")) do
      insert_log_default_time(tokens)
    else
      query
    end
  end

  defp ensure_default_time_window(query, _entity), do: query

  defp insert_log_default_time(tokens) do
    {prefix, suffix} =
      Enum.split_while(tokens, fn token ->
        not (String.starts_with?(token, "sort:") or String.starts_with?(token, "limit:"))
      end)

    Enum.join(prefix ++ ["time:last_24h"] ++ suffix, " ")
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

  defp reset_query(srql, opts) do
    case Keyword.get(opts, :default_query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> entity_baseline_query(srql, opts)
          other -> other
        end

      _ ->
        entity_baseline_query(srql, opts)
    end
  end

  defp entity_baseline_query(srql, opts) do
    entity = srql_entity(srql, opts)
    limit = reset_limit(srql, opts)

    if builder_available?(srql) do
      Builder.build(Builder.default_state(entity, limit))
    else
      default_query(entity, limit)
    end
  end

  defp reset_limit(srql, opts) do
    load_opts = Map.get(srql, :load_opts, %{})

    Keyword.get(opts, :default_limit) ||
      Map.get(load_opts, :default_limit) ||
      Map.get(srql, :default_limit) ||
      100
  end

  defp parse_builder_state(true, query, builder) do
    case Builder.parse(query) do
      {:ok, parsed} -> {true, true, parsed}
      {:error, _} -> {false, false, builder}
    end
  end

  defp parse_builder_state(false, _query, _builder), do: {false, false, %{}}

  defp srql_results(srql_module, query, cursor, limit, scope) do
    case srql_module.query(query, %{cursor: cursor, limit: limit, scope: scope}) do
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

  # Prefer limit:N inside the SRQL string; fall back to legacy URL limit=; then default.
  defp resolve_limit(query, url_limit, default, max) when is_binary(query) do
    case extract_limit_from_srql(query, max) do
      nil -> parse_limit(url_limit, default, max)
      limit -> limit
    end
  end

  defp resolve_limit(_query, url_limit, default, max) do
    parse_limit(url_limit, default, max)
  end

  defp extract_limit_from_srql(query, max) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)limit:(\d+)(?:\s|$)/, query) do
      [_, raw] ->
        case Integer.parse(raw) do
          {value, ""} when value > 0 -> min(value, max)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_limit_from_srql(_query, _max), do: nil

  # Intent reloads (no cursor) reset to page 1. Session paginate and legacy
  # ?page= URLs keep an explicit page number.
  defp resolve_pagination_page(params, socket, cursor) do
    case Map.get(params, "page") do
      nil when is_nil(cursor) ->
        1

      nil ->
        Map.get(socket.assigns, :pagination_page, 1)

      raw ->
        parse_pagination_page(raw, 1)
    end
  end

  defp parse_pagination_page(nil, default), do: default

  defp parse_pagination_page(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {page, ""} when page > 0 -> page
      _ -> default
    end
  end

  defp parse_pagination_page(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_pagination_page(_value, default), do: default

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp default_filter_field(entity, builder) when is_map(builder) do
    config = Catalog.entity(entity)
    preferred = config.default_filter_field
    mode = Builder.mode(builder)

    case Catalog.filter_fields(entity, mode) do
      list when is_list(list) ->
        if preferred in list, do: preferred, else: List.first(list) || preferred

      _ ->
        preferred
    end
  end

  defp default_filter_field(entity, _), do: Catalog.entity(entity).default_filter_field

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

    if candidate == "" do
      srql_entity(srql, opts)
    else
      candidate
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

  defp maybe_add_default_time(tokens, "logs"), do: tokens ++ ["time:last_24h"]

  defp maybe_add_default_time(tokens, entity) do
    if entity in [
         "events",
         "bmp_events",
         "otel_metrics",
         "timeseries_metrics",
         "snmp_metrics",
         "rperf_metrics",
         "cpu_metrics",
         "memory_metrics",
         "disk_metrics",
         "process_metrics",
         "attributed_flows",
         "capacity_forecasts"
       ] do
      tokens ++ ["time:last_7d"]
    else
      tokens
    end
  end
end
