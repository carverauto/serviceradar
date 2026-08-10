defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Northbound do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Automation.Northbound.Catalog, as: NorthboundCatalog
  alias ServiceRadar.Automation.Northbound.InvocationService, as: NorthboundInvocationService
  alias ServiceRadarWebNG.Northbound.ActionForm, as: NorthboundActionForm
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection

  def handle_event("run_action_for_selection", _params, socket) do
    with_current_launch_permission(socket, fn socket ->
      if socket.assigns.northbound_device_actions == [] do
        {:noreply, put_flash(socket, :error, "No launchable action integrations are configured.")}
      else
        case Selection.validate_device_selection(socket) do
          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}

          :ok ->
            action = preferred_device_action(socket.assigns.northbound_device_actions)

            {:noreply, open_northbound_action_modal(socket, action)}
        end
      end
    end)
  end

  def handle_event("close_northbound_action_modal", _params, socket) do
    {:noreply, close_northbound_action_modal(socket)}
  end

  def handle_event("northbound_action_change", %{"action" => params}, socket) do
    if can_launch_northbound_actions?(socket.assigns.current_scope) do
      action =
        params
        |> Map.get("action_id")
        |> find_launchable_northbound_action(socket.assigns.northbound_device_actions)

      form_params = NorthboundActionForm.ensure_params(params, action)

      {:noreply,
       socket
       |> assign(:northbound_launch_action, action)
       |> assign(:northbound_action_form, to_form(form_params, as: :action))
       |> assign(:northbound_action_error, nil)}
    else
      deny_launch_event(socket)
    end
  end

  def handle_event("launch_northbound_action", %{"action" => params}, socket) do
    with_current_launch_permission(socket, fn socket ->
      with {:ok, action} <-
             selected_northbound_action(params, socket.assigns.northbound_device_actions),
           {:ok, input_values} <- build_input_values(socket, action, params),
           {:ok, targets} <- selected_device_action_targets(socket),
           {:ok, invocation} <- create_northbound_invocation(socket, action, targets, input_values) do
        {:noreply,
         socket
         |> close_northbound_action_modal()
         |> assign(:selected_devices, MapSet.new())
         |> assign(:select_all_matching, false)
         |> assign(:total_matching_count, nil)
         |> put_flash(
           :info,
           "Created action invocation #{NorthboundActionForm.short_id(invocation.id)} for #{length(targets)} device(s). Open device details Action History to follow results."
         )}
      else
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:northbound_action_form, to_form(params, as: :action))
           |> assign(
             :northbound_action_error,
             NorthboundActionForm.format_launch_error(reason, "device")
           )}
      end
    end)
  end

  def maybe_load_northbound_device_actions(socket) do
    if connected?(socket) and can_launch_northbound_actions?(socket.assigns.current_scope) do
      scope = socket.assigns.current_scope

      start_async(socket, :northbound_device_actions, fn ->
        northbound_catalog_module().eligible_device_actions(scope)
      end)
    else
      assign(socket, :northbound_device_actions_loading, false)
    end
  end

  defp can_launch_northbound_actions?(scope) do
    RBAC.can?(scope, "northbound.actions.launch")
  end

  defp launch_permission_error do
    "You are not authorized to launch actions. Missing permission: northbound.actions.launch."
  end

  defp with_current_launch_permission(socket, callback) do
    case RBAC.authorize_current(socket.assigns.current_scope, ["northbound.actions.launch"]) do
      {:ok, current_scope} ->
        callback.(assign(socket, :current_scope, current_scope))

      {:error, :permission_revoked} ->
        deny_launch_event(socket)
    end
  end

  defp deny_launch_event(socket) do
    {:noreply,
     socket
     |> close_northbound_action_modal()
     |> put_flash(:error, launch_permission_error())}
  end

  defp preferred_device_action(actions) do
    List.first(actions)
  end

  defp launchable_northbound_actions(actions) when is_list(actions), do: actions
  defp launchable_northbound_actions(_actions), do: []

  defp open_northbound_action_modal(socket, nil) do
    put_flash(socket, :error, "No launchable action integration was selected.")
  end

  defp open_northbound_action_modal(socket, action) do
    params = NorthboundActionForm.default_params(action)

    socket
    |> assign(:show_northbound_action_modal, true)
    |> assign(:northbound_launch_action, action)
    |> assign(:northbound_action_form, to_form(params, as: :action))
    |> assign(:northbound_action_error, nil)
  end

  defp close_northbound_action_modal(socket) do
    socket
    |> assign(:show_northbound_action_modal, false)
    |> assign(:northbound_launch_action, nil)
    |> assign(:northbound_action_form, to_form(%{}, as: :action))
    |> assign(:northbound_action_error, nil)
  end

  defp build_input_values(_socket, action, params), do: NorthboundActionForm.parse_input(action, params)

  defp selected_northbound_action(params, actions) do
    params
    |> Map.get("action_id")
    |> find_launchable_northbound_action(actions)
    |> case do
      nil -> {:error, :action_not_found}
      action -> {:ok, action}
    end
  end

  defp find_launchable_northbound_action(id, actions) when is_binary(id) do
    actions
    |> launchable_northbound_actions()
    |> Enum.find(&(&1.id == id))
  end

  defp find_launchable_northbound_action(_id, actions) do
    actions |> launchable_northbound_actions() |> List.first()
  end

  defp selected_device_action_targets(socket) do
    targets =
      socket
      |> Selection.selected_uids()
      |> Enum.map(&%{kind: "device", device_uid: &1})

    if targets == [], do: {:error, :targets_required}, else: {:ok, targets}
  end

  defp create_northbound_invocation(socket, action, targets, input_values) do
    northbound_invocation_service_module().create_and_dispatch(
      %{
        descriptor_id: Map.get(action, :descriptor_id),
        targets: targets,
        input_values: input_values,
        source: :user,
        metadata: %{
          "ui_surface" => "devices",
          "selected_target_count" => length(targets)
        }
      },
      actor: scope_actor(socket.assigns.current_scope)
    )
  end

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    permissions = fresh_permissions(user, permissions)

    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp fresh_permissions(%ServiceRadar.Identity.User{} = user, _permissions) do
    ServiceRadar.Identity.RBAC.permissions_for_user(user, fresh?: true)
  end

  defp fresh_permissions(_user, permissions), do: permissions

  defp northbound_catalog_module do
    Application.get_env(:serviceradar_web_ng, :northbound_catalog_module, NorthboundCatalog)
  end

  defp northbound_invocation_service_module do
    Application.get_env(
      :serviceradar_web_ng,
      :northbound_invocation_service_module,
      NorthboundInvocationService
    )
  end
end
