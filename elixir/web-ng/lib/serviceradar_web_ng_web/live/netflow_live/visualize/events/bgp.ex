defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.Events.Bgp do
  @moduledoc false

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  def add_as_filter(%{"as_number" => as_number}, socket) do
    case Integer.parse(as_number) do
      {as_int, ""} when as_int > 0 and as_int <= 4_294_967_295 ->
        params = %{"field" => "as_path", "value" => to_string(as_int)}
        {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "flows")}

      _ ->
        {:noreply, socket}
    end
  end

  def add_as_filter(_params, socket), do: {:noreply, socket}

  def add_community_filter(params, socket) do
    parsed_community =
      params
      |> Map.get("community")
      |> community_value()
      |> parse_community()

    if parsed_community do
      params = %{"field" => "bgp_communities", "value" => parsed_community}
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "flows")}
    else
      {:noreply, socket}
    end
  end

  def clear_filters(_params, socket) do
    socket =
      socket
      |> SRQLPage.handle_event("srql_builder_remove_filter", %{"field" => "as_path"}, entity: "flows")
      |> SRQLPage.handle_event("srql_builder_remove_filter", %{"field" => "bgp_communities"}, entity: "flows")

    {:noreply, socket}
  end

  defp community_value(value) when is_binary(value), do: value
  defp community_value(_), do: ""

  defp parse_community(value) when is_binary(value) do
    cond do
      String.match?(value, ~r/^\d+$/) ->
        value

      String.contains?(value, ":") ->
        parse_as_value_community(value)

      true ->
        nil
    end
  end

  defp parse_as_value_community(value) do
    case String.split(value, ":") do
      [as_str, value_str] ->
        with {as_num, ""} <- Integer.parse(as_str),
             {value_num, ""} <- Integer.parse(value_str),
             true <- as_num >= 0 and as_num <= 65_535,
             true <- value_num >= 0 and value_num <= 65_535 do
          as_num |> Bitwise.bsl(16) |> Bitwise.bor(value_num) |> to_string()
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
