defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.ProfileTemplates do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  def handle_event("toggle_template", %{"id" => template_id}, socket) do
    current_ids = socket.assigns.selected_template_ids

    new_ids =
      if template_id in current_ids do
        Enum.reject(current_ids, &(&1 == template_id))
      else
        current_ids ++ [template_id]
      end

    {:noreply, assign(socket, :selected_template_ids, new_ids)}
  end

  def handle_event("remove_template", %{"id" => template_id}, socket) do
    new_ids = Enum.reject(socket.assigns.selected_template_ids, &(&1 == template_id))
    {:noreply, assign(socket, :selected_template_ids, new_ids)}
  end

  # Target modal event handlers (legacy)
end
