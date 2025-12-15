defmodule ServiceRadarWebNGWeb.SRQL.Page do
  @moduledoc false

  alias ServiceRadarWebNGWeb.SRQL.Builder

  def init(socket, entity, opts \\ []) when entity in ["devices", "pollers"] do
    default_limit = Keyword.get(opts, :default_limit, 100)
    builder = Builder.default_state(entity, default_limit)
    query = Builder.build(builder)

    srql = %{
      enabled: true,
      entity: entity,
      page_path: nil,
      query: query,
      draft: query,
      error: nil,
      loading: false,
      builder_open: false,
      builder_supported: true,
      builder_sync: true,
      builder: builder
    }

    Phoenix.Component.assign(socket, :srql, srql)
  end

  def load_list(socket, params, uri, list_assign_key, opts \\ []) when is_atom(list_assign_key) do
    srql = Map.get(socket.assigns, :srql, %{})
    entity = srql_entity(srql, opts)

    default_limit = Keyword.get(opts, :default_limit, 100)
    max_limit = Keyword.get(opts, :max_limit, 500)
    limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)

    limit = parse_limit(Map.get(params, "limit"), default_limit, max_limit)

    builder =
      srql
      |> Map.get(:builder, Builder.default_state(entity, default_limit))
      |> Map.put("entity", entity)
      |> Map.put("limit", limit)

    default_query = Builder.build(builder)
    query = Map.get(params, "q", default_query)

    {builder_supported, builder_sync, builder_state} =
      case Builder.parse(query) do
        {:ok, parsed} -> {true, true, parsed}
        {:error, _} -> {false, false, builder}
      end

    srql_module = srql_module()

    {results, error} =
      case srql_module.query(query) do
        {:ok, %{"results" => results}} when is_list(results) -> {results, nil}
        {:ok, other} -> {[], "unexpected SRQL response: #{inspect(other)}"}
        {:error, reason} -> {[], "SRQL error: #{format_error(reason)}"}
      end

    page_path = URI.parse(uri).path

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
        loading: false,
        builder_supported: builder_supported,
        builder_sync: builder_sync,
        builder: builder_state
      })

    socket
    |> Phoenix.Component.assign(:srql, srql)
    |> Phoenix.Component.assign(limit_assign_key, display_limit)
    |> Phoenix.Component.assign(list_assign_key, results)
  end

  def handle_event(socket, event, params, opts \\ [])

  def handle_event(socket, "srql_change", %{"q" => query}, _opts) do
    srql = update_srql(socket, &Map.put(&1, :draft, query))
    Phoenix.Component.assign(socket, :srql, srql)
  end

  def handle_event(socket, "srql_submit", %{"q" => raw_query}, opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    page_path = srql[:page_path] || Keyword.get(opts, :fallback_path, "/")

    query = raw_query |> to_string() |> String.trim()
    query = if query == "", do: to_string(srql[:query] || ""), else: query

    limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)
    limit = Map.get(socket.assigns, limit_assign_key)

    socket
    |> Phoenix.Component.assign(:srql, Map.put(srql, :builder_open, false))
    |> Phoenix.LiveView.push_patch(
      to: page_path <> "?" <> URI.encode_query(%{"q" => query, "limit" => limit})
    )
  end

  def handle_event(socket, "srql_builder_toggle", _params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})

    if Map.get(srql, :builder_open, false) do
      Phoenix.Component.assign(socket, :srql, Map.put(srql, :builder_open, false))
    else
      entity = srql_entity(srql, opts)
      limit_assign_key = Keyword.get(opts, :limit_assign_key, :limit)
      limit = Map.get(socket.assigns, limit_assign_key, 100)

      current = srql[:draft] || srql[:query] || ""

      {supported, sync, builder} =
        case Builder.parse(current) do
          {:ok, builder} ->
            {true, true, builder}

          {:error, _reason} ->
            {false, false, Builder.default_state(entity, limit)}
        end

      updated =
        srql
        |> Map.put(:builder_open, true)
        |> Map.put(:builder_supported, supported)
        |> Map.put(:builder_sync, sync)
        |> Map.put(:builder, builder)

      Phoenix.Component.assign(socket, :srql, updated)
    end
  end

  def handle_event(socket, "srql_builder_change", %{"builder" => params}, _opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    builder = Builder.update(Map.get(srql, :builder, %{}), params)

    updated = Map.put(srql, :builder, builder)

    updated =
      if updated[:builder_supported] and updated[:builder_sync] do
        Map.put(updated, :draft, Builder.build(builder))
      else
        updated
      end

    Phoenix.Component.assign(socket, :srql, updated)
  end

  def handle_event(socket, "srql_builder_add_filter", _params, opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    entity = srql_entity(srql, opts)
    builder = Map.get(srql, :builder, Builder.default_state(entity))

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    next = %{"field" => default_filter_field(entity, filters), "value" => ""}

    updated_builder = Map.put(builder, "filters", filters ++ [next])

    updated =
      srql
      |> Map.put(:builder, updated_builder)
      |> maybe_sync_builder_to_draft()

    Phoenix.Component.assign(socket, :srql, updated)
  end

  def handle_event(socket, "srql_builder_remove_filter", %{"idx" => idx}, opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    entity = srql_entity(srql, opts)
    builder = Map.get(srql, :builder, Builder.default_state(entity))

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    index =
      case Integer.parse(to_string(idx)) do
        {i, ""} -> i
        _ -> -1
      end

    updated_filters =
      filters
      |> Enum.with_index()
      |> Enum.reject(fn {_f, i} -> i == index end)
      |> Enum.map(fn {f, _i} -> f end)

    updated_builder =
      if updated_filters == [] do
        Map.put(builder, "filters", [
          %{"field" => default_filter_field(entity, []), "value" => ""}
        ])
      else
        Map.put(builder, "filters", updated_filters)
      end

    updated =
      srql
      |> Map.put(:builder, updated_builder)
      |> maybe_sync_builder_to_draft()

    Phoenix.Component.assign(socket, :srql, updated)
  end

  def handle_event(socket, "srql_builder_apply", _params, _opts) do
    srql = Map.get(socket.assigns, :srql, %{})
    builder = Map.get(srql, :builder, %{})
    query = Builder.build(builder)

    updated =
      srql
      |> Map.put(:builder_supported, true)
      |> Map.put(:builder_sync, true)
      |> Map.put(:draft, query)

    Phoenix.Component.assign(socket, :srql, updated)
  end

  defp srql_entity(srql, opts) do
    case Map.get(srql, :entity) || Keyword.get(opts, :entity) do
      "devices" -> "devices"
      "pollers" -> "pollers"
      _ -> "devices"
    end
  end

  defp update_srql(socket, fun) do
    socket.assigns
    |> Map.get(:srql, %{})
    |> fun.()
  end

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
    case entity do
      "pollers" -> "poller_id"
      _ -> "hostname"
    end
  end
end
