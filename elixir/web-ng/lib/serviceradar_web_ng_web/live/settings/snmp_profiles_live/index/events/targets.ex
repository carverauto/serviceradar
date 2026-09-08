defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.Targets do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias AshPhoenix.Form
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Connectivity
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.FormHelpers

  def handle_event("open_target_modal", _params, socket) do
    scope = socket.assigns.current_scope
    profile_id = socket.assigns.selected_profile.id

    target_form =
      Form.for_create(SNMPTarget, :create,
        domain: ServiceRadar.SNMPProfiles,
        scope: scope,
        params: %{snmp_profile_id: profile_id}
      )

    {:noreply,
     socket
     |> assign(:show_target_modal, true)
     |> assign(:target_form, to_form(target_form))
     |> assign(:editing_target, nil)
     |> assign(:show_password, false)
     |> assign(:target_oids, [])
     |> assign(:show_template_browser, false)
     |> assign(:test_connection_result, nil)
     |> assign(:test_connection_loading, false)}
  end

  def handle_event("edit_target", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Data.load_target(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Target not found")}

      target ->
        target_form =
          Form.for_update(target, :update, domain: ServiceRadar.SNMPProfiles, scope: scope)

        # Load existing OIDs for this target
        oids = Data.load_target_oids(scope, target.id)

        {:noreply,
         socket
         |> assign(:show_target_modal, true)
         |> assign(:target_form, to_form(target_form))
         |> assign(:editing_target, target)
         |> assign(:show_password, false)
         |> assign(:target_oids, oids)
         |> assign(:show_template_browser, false)
         |> assign(:test_connection_result, nil)
         |> assign(:test_connection_loading, false)}
    end
  end

  def handle_event("close_target_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_target_modal, false)
     |> assign(:target_form, nil)
     |> assign(:editing_target, nil)
     |> assign(:show_password, false)
     |> assign(:target_oids, [])
     |> assign(:show_template_browser, false)
     |> assign(:test_connection_result, nil)
     |> assign(:test_connection_loading, false)}
  end

  def handle_event("toggle_password_visibility", _params, socket) do
    {:noreply, assign(socket, :show_password, !socket.assigns.show_password)}
  end

  def handle_event("validate_target", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope

    target_form =
      if socket.assigns.editing_target do
        Form.for_update(socket.assigns.editing_target, :update,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope
        )
      else
        profile_id = socket.assigns.selected_profile.id

        Form.for_create(SNMPTarget, :create,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope,
          params: %{snmp_profile_id: profile_id}
        )
      end

    target_form = Form.validate(target_form, params)

    {:noreply, assign(socket, :target_form, to_form(target_form))}
  end

  def handle_event("save_target", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    profile_id = socket.assigns.selected_profile.id

    # When editing, remove blank password/community fields from params
    # to avoid accidentally clearing existing encrypted credentials.
    params =
      if socket.assigns.editing_target do
        sensitive_fields = ["community", "auth_password", "priv_password"]

        Map.reject(params, fn {key, value} ->
          key in sensitive_fields and value == ""
        end)
      else
        params
      end

    target_form =
      if socket.assigns.editing_target do
        Form.for_update(socket.assigns.editing_target, :update,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope
        )
      else
        Form.for_create(SNMPTarget, :create,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope,
          params: %{snmp_profile_id: profile_id}
        )
      end

    target_form = Form.validate(target_form, params)

    case Form.submit(target_form, params: params) do
      {:ok, _target} ->
        action = if socket.assigns.editing_target, do: "updated", else: "created"
        targets = Data.load_profile_targets(scope, profile_id)

        {:noreply,
         socket
         |> assign(:targets, targets)
         |> assign(:show_target_modal, false)
         |> assign(:target_form, nil)
         |> assign(:editing_target, nil)
         |> put_flash(:info, "Target #{action} successfully")}

      {:error, form} ->
        {:noreply, assign(socket, :target_form, to_form(form))}
    end
  end

  def handle_event("delete_target", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    profile_id = socket.assigns.selected_profile.id

    case Data.load_target(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Target not found")}

      target ->
        case Ash.destroy(target, scope: scope) do
          :ok ->
            targets = Data.load_profile_targets(scope, profile_id)

            {:noreply,
             socket
             |> assign(:targets, targets)
             |> put_flash(:info, "Target deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete target")}
        end
    end
  end

  def handle_event("test_connection", _params, socket) do
    form = socket.assigns.target_form

    # Get form values - handle both source formats
    host = FormHelpers.get_form_value(form, :host, "")
    port = FormHelpers.get_form_value(form, :port, 161)

    # Convert port to integer if needed
    port =
      case port do
        p when is_integer(p) ->
          p

        p when is_binary(p) ->
          case Integer.parse(p) do
            {int, _} -> int
            :error -> 161
          end
      end

    # Validate we have a host
    if host == "" do
      {:noreply,
       assign(socket, :test_connection_result, %{
         success: false,
         message: "Please enter a host address first"
       })}
    else
      # Set loading state and run the (blocking DNS + UDP) probe off the
      # LiveView process via the app TaskSupervisor. The previous send(self())
      # + handle_info pattern ran the probe inside the LV process, blocking it
      # for up to the 3s UDP recv and serializing all LV messages behind it.
      socket = assign(socket, :test_connection_loading, true)

      Task.Supervisor.async_nolink(
        ServiceRadarWebNG.TaskSupervisor,
        fn -> Connectivity.test_snmp_connectivity(host, port) end
      )

      {:noreply, socket}
    end
  end

  # OID management event handlers
end
