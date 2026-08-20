defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.TargetOids do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  def handle_event("add_oid", _params, socket) do
    new_oid = %{
      "oid" => "",
      "name" => "",
      "data_type" => "gauge",
      "scale" => "1.0",
      "delta" => false,
      "mode" => "get",
      "temp_id" => System.unique_integer([:positive])
    }

    oids = socket.assigns.target_oids ++ [new_oid]
    {:noreply, assign(socket, :target_oids, oids)}
  end

  def handle_event("remove_oid", %{"index" => index_str}, socket) do
    index =
      case Integer.parse(index_str) do
        {n, _} -> n
        _ -> nil
      end

    if index do
      oids = List.delete_at(socket.assigns.target_oids, index)
      {:noreply, assign(socket, :target_oids, oids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_oid", %{"index" => index_str, "field" => field} = params, socket) do
    index =
      case Integer.parse(index_str) do
        {n, _} -> n
        _ -> nil
      end

    if index do
      oids = socket.assigns.target_oids
      current_oid = Enum.at(oids, index)

      # Get the new value for the changed field
      # - For text inputs (phx-blur): fresh value is in params["value"]
      # - For select (phx-change): fresh value is in params["value"]
      # - For checkbox (phx-click): toggled value is in params["delta"]
      new_value =
        case field do
          "delta" -> Map.get(params, "delta", "false") == "true"
          _ -> Map.get(params, "value", "")
        end

      updated_oid = Map.put(current_oid, field, new_value)
      updated_oids = List.replace_at(oids, index, updated_oid)
      {:noreply, assign(socket, :target_oids, updated_oids)}
    else
      {:noreply, socket}
    end
  end
end
