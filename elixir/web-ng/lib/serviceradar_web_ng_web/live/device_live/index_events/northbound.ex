defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Northbound do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Automation.Northbound.Catalog, as: NorthboundCatalog
  alias ServiceRadar.Automation.Northbound.InvocationService, as: NorthboundInvocationService
  alias ServiceRadarWebNG.Northbound.ActionForm, as: NorthboundActionForm
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.AwxApplicability
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection
  alias ServiceRadarWebNGWeb.DeviceLive.RunTaskVariables

  def handle_event("run_task_for_selection", _params, socket) do
    cond do
      not can_launch_northbound_actions?(socket.assigns.current_scope) ->
        {:noreply, put_flash(socket, :error, launch_permission_error())}

      socket.assigns.northbound_device_actions == [] ->
        {:noreply, put_flash(socket, :error, "No launchable task integrations are configured.")}

      true ->
        case Selection.validate_device_selection(socket) do
          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}

          :ok ->
            # Classify the selection so the modal can call out (and skip) the
            # devices that are not in an AWX inventory.
            applicability =
              AwxApplicability.classify(
                socket.assigns.current_scope,
                Selection.selected_uids(socket)
              )

            socket = assign(socket, :northbound_awx_applicability, applicability)
            action = preferred_device_action(socket.assigns.northbound_device_actions)

            {:noreply, open_northbound_action_modal(socket, action)}
        end
    end
  end

  def handle_event("close_northbound_action_modal", _params, socket) do
    {:noreply, close_northbound_action_modal(socket)}
  end

  def handle_event("toggle_northbound_raw_extra_vars", _params, socket) do
    {:noreply, assign(socket, :northbound_raw_extra_vars_open, not socket.assigns.northbound_raw_extra_vars_open)}
  end

  def handle_event("northbound_action_change", %{"action" => params}, socket) do
    action =
      params
      |> Map.get("action_id")
      |> find_launchable_northbound_action(socket.assigns.northbound_device_actions)

    form_params = NorthboundActionForm.ensure_params(params, action)

    {:noreply,
     socket
     |> assign(:northbound_launch_action, action)
     |> assign(:northbound_action_form, to_form(form_params, as: :action))
     |> assign(:northbound_action_error, nil)
     |> sync_ansible_var_state(action, params)}
  end

  def handle_event("launch_northbound_action", %{"action" => params}, socket) do
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
         "Created task invocation #{NorthboundActionForm.short_id(invocation.id)} for #{length(targets)} device(s). Open device details Task History to follow results."
       )}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:northbound_action_form, to_form(params, as: :action))
         |> preserve_ansible_form_state(params)
         |> assign(
           :northbound_action_error,
           NorthboundActionForm.format_launch_error(reason, "device")
         )}
    end
  end

  def maybe_load_northbound_device_actions(socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope

      start_async(socket, :northbound_device_actions, fn ->
        northbound_catalog_module().eligible_device_actions(scope)
      end)
    else
      socket
    end
  end

  defp can_launch_northbound_actions?(scope) do
    RBAC.can?(scope, "northbound.actions.launch") or RBAC.can?(scope, "ansible.runs.launch")
  end

  defp launch_permission_error do
    "You are not authorized to launch tasks. Missing permission: northbound.actions.launch."
  end

  defp preferred_device_action(actions) do
    List.first(actions)
  end

  defp launchable_northbound_actions(actions) when is_list(actions), do: actions
  defp launchable_northbound_actions(_actions), do: []

  defp open_northbound_action_modal(socket, nil) do
    put_flash(socket, :error, "No launchable task integration was selected.")
  end

  defp open_northbound_action_modal(socket, action) do
    params = NorthboundActionForm.default_params(action)

    socket
    |> assign(:show_northbound_action_modal, true)
    |> assign(:northbound_launch_action, action)
    |> assign(:northbound_action_form, to_form(params, as: :action))
    |> assign(:northbound_action_error, nil)
    |> assign(:northbound_raw_extra_vars_open, false)
    |> assign(:northbound_raw_extra_vars, "")
    |> init_ansible_var_state(action)
  end

  defp close_northbound_action_modal(socket) do
    socket
    |> assign(:show_northbound_action_modal, false)
    |> assign(:northbound_launch_action, nil)
    |> assign(:northbound_action_form, to_form(%{}, as: :action))
    |> assign(:northbound_action_error, nil)
    |> assign(:northbound_awx_applicability, nil)
    |> assign(:northbound_ansible_playbook_id, nil)
    |> assign(:northbound_ansible_vars, nil)
    |> assign(:northbound_ansible_var_values, %{})
    |> assign(:northbound_raw_extra_vars_open, false)
    |> assign(:northbound_raw_extra_vars, "")
  end

  ## Ansible typed-variable form ------------------------------------------------

  defp init_ansible_var_state(socket, action) do
    case RunTaskVariables.playbook_id(action) do
      nil ->
        clear_ansible_var_state(socket)

      playbook_id ->
        vars = RunTaskVariables.load_vars(playbook_id)

        socket
        |> assign(:northbound_ansible_playbook_id, playbook_id)
        |> assign(:northbound_ansible_vars, vars)
        |> assign(:northbound_ansible_var_values, RunTaskVariables.default_values(vars))
    end
  end

  # phx-change: track typed values + raw JSON, and reload the schema when the
  # operator switches to a task backed by a different playbook.
  defp sync_ansible_var_state(socket, action, params) do
    socket = assign(socket, :northbound_raw_extra_vars, raw_extra_vars_param(socket, params))
    new_playbook_id = RunTaskVariables.playbook_id(action)

    cond do
      is_nil(new_playbook_id) ->
        clear_ansible_var_state(socket)

      new_playbook_id == socket.assigns.northbound_ansible_playbook_id ->
        assign(
          socket,
          :northbound_ansible_var_values,
          merge_var_values(socket, params)
        )

      true ->
        vars = RunTaskVariables.load_vars(new_playbook_id)

        socket
        |> assign(:northbound_ansible_playbook_id, new_playbook_id)
        |> assign(:northbound_ansible_vars, vars)
        |> assign(:northbound_ansible_var_values, RunTaskVariables.default_values(vars))
    end
  end

  # On a failed submit, keep the operator's typed values + raw JSON on screen.
  defp preserve_ansible_form_state(socket, params) do
    if is_list(socket.assigns[:northbound_ansible_vars]) do
      socket
      |> assign(:northbound_ansible_var_values, merge_var_values(socket, params))
      |> assign(:northbound_raw_extra_vars, raw_extra_vars_param(socket, params))
    else
      socket
    end
  end

  defp clear_ansible_var_state(socket) do
    socket
    |> assign(:northbound_ansible_playbook_id, nil)
    |> assign(:northbound_ansible_vars, nil)
    |> assign(:northbound_ansible_var_values, %{})
  end

  defp merge_var_values(socket, params) do
    Map.merge(
      socket.assigns.northbound_ansible_var_values,
      RunTaskVariables.values_from_params(socket.assigns.northbound_ansible_vars || [], params["vars"] || %{})
    )
  end

  defp raw_extra_vars_param(socket, params) do
    case Map.get(params, "raw_extra_vars") do
      raw when is_binary(raw) -> raw
      _ -> socket.assigns[:northbound_raw_extra_vars] || ""
    end
  end

  # Ansible tasks build `extra_vars` from the typed form (+ optional raw JSON);
  # non-ansible tasks keep the descriptor's JSON-schema casting.
  defp build_input_values(socket, action, params) do
    if RunTaskVariables.ansible?(action) do
      raw =
        if socket.assigns.northbound_raw_extra_vars_open,
          do: socket.assigns.northbound_raw_extra_vars

      case RunTaskVariables.extra_vars(socket.assigns.northbound_ansible_vars, params["vars"] || %{}, raw) do
        {:ok, extra_vars} -> {:ok, %{"extra_vars" => extra_vars}}
        {:error, message} -> {:error, {:invalid_extra_vars_json, message}}
      end
    else
      NorthboundActionForm.parse_input(action, params)
    end
  end

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

  # Only ever target the AWX-managed subset classified when the modal opened;
  # non-applicable devices are skipped (and were called out in the modal).
  defp selected_device_action_targets(socket) do
    targets =
      socket.assigns
      |> Map.get(:northbound_awx_applicability)
      |> applicable_uids()
      |> Enum.map(&%{kind: "device", device_uid: &1})

    if targets == [], do: {:error, :no_applicable_devices}, else: {:ok, targets}
  end

  defp applicable_uids(%AwxApplicability{applicable_uids: uids}), do: uids
  defp applicable_uids(_), do: []

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
