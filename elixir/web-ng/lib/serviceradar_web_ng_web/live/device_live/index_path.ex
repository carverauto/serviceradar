defmodule ServiceRadarWebNGWeb.DeviceLive.IndexPath do
  @moduledoc false

  @list_path "/devices"

  def list_path(opts \\ []) do
    page = page_param(Keyword.get(opts, :page))
    # Page 1 is the list head (offset 0). Keeping a leftover keyset cursor
    # makes handle_params treat this as "still on a later page".
    cursor = if is_nil(page), do: nil, else: Keyword.get(opts, :cursor)

    params =
      %{}
      |> maybe_put("q", Keyword.get(opts, :query))
      |> maybe_put("page", page)
      |> maybe_put("cursor", cursor)

    encode_path(@list_path, params)
  end

  def list_path_from_assigns(assigns) when is_map(assigns) do
    case assigns[:last_uri] do
      uri when is_binary(uri) ->
        from_uri(uri)

      _ ->
        list_path(
          query: get_in(assigns, [:srql, :query]),
          page: Map.get(assigns, :current_page) || Map.get(assigns, :pagination_page)
        )
    end
  end

  def from_uri(uri) when is_binary(uri), do: uri |> URI.parse() |> path_and_query() |> sanitize()
  def from_uri(_uri), do: @list_path

  def show_path(device_uid, opts \\ []) when is_binary(device_uid) do
    tab = Keyword.get(opts, :tab)
    tab = if tab in [nil, "", "details"], do: nil, else: to_string(tab)

    params =
      %{}
      |> maybe_put("tab", tab)
      |> maybe_put("return_to", Keyword.get(opts, :return_to))

    encode_path("/devices/#{device_uid}", params)
  end

  def sanitize(value) when is_binary(value) do
    parsed = URI.parse(String.trim(value))

    if parsed.path == @list_path do
      path_and_query(%URI{path: @list_path, query: parsed.query})
    else
      @list_path
    end
  end

  def sanitize(_value), do: @list_path

  defp page_param(page) when page in [nil, "", 1, "1"], do: nil
  defp page_param(page), do: to_string(page)

  defp path_and_query(%URI{path: path, query: query}) do
    path = path || @list_path

    case query do
      q when is_binary(q) and q != "" -> path <> "?" <> q
      _ -> path
    end
  end

  defp encode_path(path, params) when params == %{}, do: path
  defp encode_path(path, params), do: path <> "?" <> URI.encode_query(params)

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
