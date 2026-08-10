defmodule ServiceRadarWebNGWeb.DeviceLive.NorthboundInterfaceRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, start_async: 3]

  alias ServiceRadar.Automation.Northbound.Catalog, as: NorthboundCatalog
  alias ServiceRadar.Automation.Northbound.InvocationService, as: NorthboundInvocationService
  alias ServiceRadarWebNG.Northbound.ActionForm, as: NorthboundActionForm
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.NorthboundHistoryData

  def maybe_load_actions(socket) do
    cond do
      not connected?(socket) ->
        socket

      Map.get(socket.assigns, :northbound_interface_actions_loading) == true ->
        socket

      Map.get(socket.assigns, :northbound_interface_actions_loaded) == true ->
        socket

      true ->
        scope = socket.assigns.current_scope

        socket
        |> assign(:northbound_interface_actions_loading, true)
        |> start_async(:northbound_interface_actions, fn ->
          catalog_module().eligible_interface_actions(scope)
        end)
    end
  end

  def can_launch?(scope), do: RBAC.can?(scope, "northbound.actions.launch")

  def launch_permission_error do
    "You are not authorized to launch actions. Missing permission: northbound.actions.launch."
  end

  def open_modal(socket, nil) do
    put_flash(socket, :error, "No launchable interface action integration was selected.")
  end

  def open_modal(socket, action) do
    params = NorthboundActionForm.default_params(action)

    socket
    |> assign(:show_northbound_interface_action_modal, true)
    |> assign(:northbound_interface_launch_action, action)
    |> assign(:northbound_interface_action_form, to_form(params, as: :action))
    |> assign(:northbound_interface_action_error, nil)
  end

  def close_modal(socket) do
    socket
    |> assign(:show_northbound_interface_action_modal, false)
    |> assign(:northbound_interface_launch_action, nil)
    |> assign(:northbound_interface_action_form, to_form(%{}, as: :action))
    |> assign(:northbound_interface_action_error, nil)
  end

  def change_action(socket, params) do
    if can_launch?(socket.assigns.current_scope) do
      action =
        params
        |> Map.get("action_id")
        |> find_action(socket.assigns.northbound_interface_actions)

      params = NorthboundActionForm.ensure_params(params, action)

      socket
      |> assign(:northbound_interface_launch_action, action)
      |> assign(:northbound_interface_action_form, to_form(params, as: :action))
      |> assign(:northbound_interface_action_error, nil)
    else
      deny_launch_event(socket)
    end
  end

  def launch(socket, params) do
    case RBAC.authorize_current(socket.assigns.current_scope, ["northbound.actions.launch"]) do
      {:ok, current_scope} ->
        socket
        |> assign(:current_scope, current_scope)
        |> do_launch(params)

      {:error, :permission_revoked} ->
        deny_launch_event(socket)
    end
  end

  defp do_launch(socket, params) do
    with {:ok, action} <- selected_action(params, socket.assigns.northbound_interface_actions),
         {:ok, input_values} <- NorthboundActionForm.parse_input(action, params),
         {:ok, targets} <- selected_targets(socket),
         {:ok, invocation} <- create_invocation(socket, action, targets, input_values) do
      {history, history_error} =
        NorthboundHistoryData.load(socket.assigns.current_scope, socket.assigns.device_uid)

      socket
      |> close_modal()
      |> assign(:selected_interfaces, MapSet.new())
      |> assign(:northbound_device_history, history)
      |> assign(:northbound_device_history_error, history_error)
      |> assign(:northbound_launch_notice, %{
        title: "Action dispatched for #{length(targets)} interface(s)",
        invocation_id: invocation.id
      })
      |> put_flash(:info, "Action dispatched. Watch Action History for results.")
    else
      {:error, reason} ->
        socket
        |> assign(:northbound_interface_action_form, to_form(params, as: :action))
        |> assign(
          :northbound_interface_action_error,
          NorthboundActionForm.format_launch_error(reason, "interface")
        )
    end
  end

  defp deny_launch_event(socket) do
    socket
    |> close_modal()
    |> put_flash(:error, launch_permission_error())
  end

  defp selected_action(params, actions) do
    params
    |> Map.get("action_id")
    |> find_action(actions)
    |> case do
      nil -> {:error, :action_not_found}
      action -> {:ok, action}
    end
  end

  defp find_action(id, actions) when is_binary(id) and is_list(actions) do
    Enum.find(actions, &(&1.id == id))
  end

  defp find_action(_id, actions) when is_list(actions), do: List.first(actions)
  defp find_action(_id, _actions), do: nil

  defp selected_targets(socket) do
    device_uid = socket.assigns.device_uid

    targets =
      socket.assigns.selected_interfaces
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(&%{kind: "interface", device_uid: device_uid, interface_uid: &1})

    if targets == [], do: {:error, :targets_required}, else: {:ok, targets}
  end

  defp create_invocation(socket, action, targets, input_values) do
    invocation_service_module().create_and_dispatch(
      %{
        descriptor_id: Map.get(action, :descriptor_id),
        targets: targets,
        input_values: input_values,
        source: :user,
        metadata: %{
          "ui_surface" => "device_interfaces",
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

  defp catalog_module do
    Application.get_env(:serviceradar_web_ng, :northbound_catalog_module, NorthboundCatalog)
  end

  defp invocation_service_module do
    Application.get_env(
      :serviceradar_web_ng,
      :northbound_invocation_service_module,
      NorthboundInvocationService
    )
  end
end
