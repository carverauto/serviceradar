defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.AgentPicker do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data,
    only: [load_agent_by_uid: 2, load_agents_by_uids: 2]

  alias ServiceRadar.Infrastructure.AgentPicker, as: AgentPickerQuery
  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker

  def handle_event("agent_picker_open", _params, socket) do
    picker = AgentPicker.open(socket.assigns.agent_picker)

    {:noreply,
     socket
     |> assign(:agent_picker_open, true)
     |> assign(:agent_picker_selected_rows, [])
     |> load_browse_page(picker)}
  end

  def handle_event("agent_picker_cancel", _params, socket) do
    picker = AgentPicker.cancel(socket.assigns.agent_picker)

    {:noreply,
     socket
     |> assign(:agent_picker, picker)
     |> assign(:agent_picker_open, false)
     |> assign(:agent_picker_selected_rows, [])}
  end

  def handle_event("agent_picker_search", params, socket) do
    search = Map.get(params, "value", Map.get(params, "search", ""))
    picker = AgentPicker.search(socket.assigns.agent_picker, search)
    {:noreply, load_browse_page(socket, picker)}
  end

  def handle_event("agent_picker_retry", _params, socket) do
    {:noreply, load_browse_page(socket, socket.assigns.agent_picker)}
  end

  def handle_event("agent_picker_next", _params, socket) do
    paginate_browse(socket, &AgentPicker.next_page/1)
  end

  def handle_event("agent_picker_previous", _params, socket) do
    paginate_browse(socket, &AgentPicker.previous_page/1)
  end

  def handle_event("agent_picker_toggle", %{"uid" => uid}, socket) do
    {:noreply, update(socket, :agent_picker, &AgentPicker.toggle(&1, uid))}
  end

  def handle_event("agent_picker_show_browse", _params, socket) do
    {:noreply, update(socket, :agent_picker, &AgentPicker.show_browse/1)}
  end

  def handle_event("agent_picker_show_selected", _params, socket) do
    picker = AgentPicker.show_selected(socket.assigns.agent_picker)
    {:noreply, load_selected_rows(socket, picker)}
  end

  def handle_event("agent_picker_selected_next", _params, socket) do
    paginate_selected(socket, &AgentPicker.selected_next_page/1)
  end

  def handle_event("agent_picker_selected_previous", _params, socket) do
    paginate_selected(socket, &AgentPicker.selected_previous_page/1)
  end

  def handle_event("agent_picker_selected_retry", _params, socket) do
    {:noreply, load_selected_rows(socket, socket.assigns.agent_picker)}
  end

  def handle_event("agent_picker_remove", %{"uid" => uid}, socket) do
    picker = AgentPicker.remove(socket.assigns.agent_picker, uid)
    {:noreply, load_selected_rows(socket, picker)}
  end

  def handle_event("agent_picker_clear", _params, socket) do
    picker = AgentPicker.clear(socket.assigns.agent_picker)

    {:noreply,
     socket
     |> assign(:agent_picker, picker)
     |> assign(:agent_picker_selected_rows, [])}
  end

  def handle_event("agent_picker_apply", _params, socket) do
    picker = AgentPicker.apply(socket.assigns.agent_picker)

    {:noreply,
     socket
     |> assign(:agent_picker, picker)
     |> assign(:agent_picker_open, false)
     |> assign(:agent_picker_selected_rows, [])
     |> assign_summary_agent(picker)}
  end

  def handle_event("agent_picker_use_all", _params, socket) do
    picker = socket.assigns.agent_picker |> AgentPicker.clear() |> AgentPicker.apply()

    {:noreply,
     socket
     |> assign(:agent_picker, picker)
     |> assign(:agent_picker_open, false)
     |> assign(:agent_picker_selected_rows, [])
     |> assign(:agent_picker_summary_agent, nil)}
  end

  defp paginate_browse(socket, transition) do
    picker = transition.(socket.assigns.agent_picker)

    if picker == socket.assigns.agent_picker do
      {:noreply, socket}
    else
      {:noreply, load_browse_page(socket, picker)}
    end
  end

  defp load_browse_page(socket, picker) do
    %{search: search, selector: selector} = AgentPicker.browse_request(picker)

    loaded_picker =
      case AgentPickerQuery.page(socket.assigns.current_scope, search, selector) do
        {:ok, page} -> AgentPicker.loaded(picker, page)
        {:error, reason} -> AgentPicker.loaded(picker, {:error, reason})
      end

    assign(socket, :agent_picker, loaded_picker)
  end

  defp load_selected_rows(socket, picker) do
    %{uids: uids} = AgentPicker.selected_page(picker)

    case load_agents_by_uids(socket.assigns.current_scope, uids) do
      {:ok, agents} ->
        agents_by_uid = Map.new(agents, &{&1.uid, &1})
        rows = Enum.map(uids, &%{uid: &1, agent: Map.get(agents_by_uid, &1)})

        socket
        |> assign(:agent_picker, AgentPicker.selected_loaded(picker, :ok))
        |> assign(:agent_picker_selected_rows, rows)

      {:error, reason} ->
        socket
        |> assign(:agent_picker, AgentPicker.selected_loaded(picker, {:error, reason}))
        |> assign(:agent_picker_selected_rows, [])
    end
  end

  defp assign_summary_agent(socket, picker) do
    case picker.committed |> MapSet.to_list() |> Enum.sort() do
      [uid] -> assign(socket, :agent_picker_summary_agent, load_agent_by_uid(socket.assigns.current_scope, uid))
      _ -> assign(socket, :agent_picker_summary_agent, nil)
    end
  end

  defp paginate_selected(socket, transition) do
    picker = transition.(socket.assigns.agent_picker)

    if picker == socket.assigns.agent_picker do
      {:noreply, socket}
    else
      {:noreply, load_selected_rows(socket, picker)}
    end
  end
end
